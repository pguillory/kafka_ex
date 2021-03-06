defmodule KafkaEx.Server0P9P0 do
  @moduledoc """
  Implements kafkaEx.Server behaviors for kafka 0.9.0 API.
  """
  use KafkaEx.Server
  alias KafkaEx.Protocol.ConsumerMetadata
  alias KafkaEx.Protocol.ConsumerMetadata.Response, as: ConsumerMetadataResponse
  alias KafkaEx.Protocol.Fetch
  alias KafkaEx.Protocol.Fetch.Request, as: FetchRequest
  alias KafkaEx.Protocol.Heartbeat
  alias KafkaEx.Protocol.JoinGroup
  alias KafkaEx.Protocol.JoinGroup.Request, as: JoinGroupRequest
  alias KafkaEx.Protocol.Metadata.Broker
  alias KafkaEx.Protocol.Metadata.Response, as: MetadataResponse
  alias KafkaEx.Protocol.OffsetFetch
  alias KafkaEx.Protocol.OffsetCommit
  alias KafkaEx.Protocol.SyncGroup
  alias KafkaEx.Server.State
  alias KafkaEx.NetworkClient

  @consumer_group_update_interval 30_000

  def start_link(server_impl, args, name \\ __MODULE__)

  def start_link(server_impl, args, :no_name) do
    GenServer.start_link(__MODULE__, [server_impl, args])
  end
  def start_link(server_impl, args, name) do
    GenServer.start_link(__MODULE__, [server_impl, args, name], [name: name])
  end

  def kafka_server_init([args]) do
    kafka_server_init([args, self])
  end

  def kafka_server_init([args, name]) do
    uris = Keyword.get(args, :uris, [])
    metadata_update_interval = Keyword.get(args, :metadata_update_interval, @metadata_update_interval)
    consumer_group_update_interval = Keyword.get(args, :consumer_group_update_interval, @consumer_group_update_interval)

    # this should have already been validated, but it's possible someone could
    # try to short-circuit the start call
    consumer_group = Keyword.get(args, :consumer_group)
    true = KafkaEx.valid_consumer_group?(consumer_group)

    brokers = Enum.map(uris, fn({host, port}) -> %Broker{host: host, port: port, socket: NetworkClient.create_socket(host, port)} end)
    sync_timeout = Keyword.get(args, :sync_timeout, Application.get_env(:kafka_ex, :sync_timeout, @sync_timeout))
    {correlation_id, metadata} = retrieve_metadata(brokers, 0, sync_timeout)
    state = %State{metadata: metadata, brokers: brokers, correlation_id: correlation_id, consumer_group: consumer_group, metadata_update_interval: metadata_update_interval, consumer_group_update_interval: consumer_group_update_interval, worker_name: name, sync_timeout: sync_timeout}
    {:ok, _} = :timer.send_interval(state.metadata_update_interval, :update_metadata)

    # only start the consumer group update cycle if we are using consumer groups
    if consumer_group?(state) do
      {:ok, _} = :timer.send_interval(state.consumer_group_update_interval, :update_consumer_metadata)
    end

    {:ok, state}
  end

  def kafka_server_consumer_group(state) do
    {:reply, state.consumer_group, state}
  end

  def kafka_server_fetch(fetch_request, state) do
    true = consumer_group_if_auto_commit?(fetch_request.auto_commit, state)
    {response, state} = fetch(fetch_request, state)

    {:reply, response, state}
  end

  def kafka_server_offset_fetch(offset_fetch, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)

    # if the request is for a specific consumer group, use that
    # otherwise use the worker's consumer group
    consumer_group = offset_fetch.consumer_group || state.consumer_group
    offset_fetch = %{offset_fetch | consumer_group: consumer_group}

    offset_fetch_request = OffsetFetch.create_request(state.correlation_id, @client_id, offset_fetch)

    {response, state} = case broker do
      nil    ->
        Logger.log(:error, "Coordinator for topic #{offset_fetch.topic} is not available")
        {:topic_not_found, state}
      _ ->
        response = broker
          |> NetworkClient.send_sync_request(offset_fetch_request, state.sync_timeout)
          |> OffsetFetch.parse_response
        {response, %{state | correlation_id: state.correlation_id + 1}}
    end

    {:reply, response, state}
  end

  def kafka_server_offset_commit(offset_commit_request, state) do
    {response, state} = offset_commit(state, offset_commit_request)

    {:reply, response, state}
  end

  def kafka_server_consumer_group_metadata(state) do
    true = consumer_group?(state)
    {consumer_metadata, state} = update_consumer_metadata(state)
    {:reply, consumer_metadata, state}
  end

  def kafka_server_join_group(topics, session_timeout, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)
    request = JoinGroup.create_request(
      %JoinGroupRequest{
        correlation_id: state.correlation_id,
        client_id: @client_id, member_id: "",
        group_name: state.consumer_group,
        topics: topics, session_timeout: session_timeout
      }
    )
    response = broker
      |> NetworkClient.send_sync_request(request, state.sync_timeout)
      |> JoinGroup.parse_response
    {:reply, response, %{state | correlation_id: state.correlation_id + 1}}
  end

  def kafka_server_sync_group(group_name, generation_id, member_id, assignments, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)
    request = SyncGroup.create_request(state.correlation_id, @client_id, group_name, generation_id, member_id, assignments)
    response = broker
      |> NetworkClient.send_sync_request(request, state.sync_timeout)
      |> SyncGroup.parse_response
    {:reply, response, %{state | correlation_id: state.correlation_id + 1}}
  end

  def kafka_server_heartbeat(group_name, generation_id, member_id, state) do
    true = consumer_group?(state)
    {broker, state} = broker_for_consumer_group_with_update(state)
    request = Heartbeat.create_request(state.correlation_id, @client_id, member_id, group_name, generation_id)
    response = broker
      |> NetworkClient.send_sync_request(request, state.sync_timeout)
      |> Heartbeat.parse_response
    {:reply, response, %{state | correlation_id: state.correlation_id + 1}}
  end

  def kafka_server_start_streaming(_, state = %State{event_pid: nil}) do
    # our streaming could have been canceled with a streaming update in-flight
    {:noreply, state}
  end
  def kafka_server_start_streaming(fetch_request, state) do
    true = consumer_group_if_auto_commit?(fetch_request.auto_commit, state)

    {response, state} = fetch(fetch_request, state)
    offset = case response do
               :topic_not_found ->
                 fetch_request.offset
               _ ->
                 message = response |> hd |> Map.get(:partitions) |> hd
                 Enum.each(message.message_set, fn(message_set) -> GenEvent.notify(state.event_pid, message_set) end)
                 case message.last_offset do
                   nil         -> fetch_request.offset
                   last_offset -> last_offset + 1
                 end
             end

    ref = Process.send_after(
      self, {:start_streaming, %{fetch_request | offset: offset}}, 500
    )

    {:noreply, %{state | stream_timer: ref}}
  end

  def kafka_server_update_consumer_metadata(state) do
    true = consumer_group?(state)
    {_, state} = update_consumer_metadata(state)
    {:noreply, state}
  end

  defp update_consumer_metadata(state), do: update_consumer_metadata(state, @retry_count, 0)

  defp update_consumer_metadata(state = %State{consumer_group: consumer_group}, 0, error_code) do
    Logger.log(:error, "Fetching consumer_group #{consumer_group} metadata failed with error_code #{inspect error_code}")
    {%ConsumerMetadataResponse{error_code: error_code}, state}
  end

  defp update_consumer_metadata(state = %State{consumer_group: consumer_group, correlation_id: correlation_id}, retry, _error_code) do
    response = correlation_id
      |> ConsumerMetadata.create_request(@client_id, consumer_group)
      |> first_broker_response(state)
      |> ConsumerMetadata.parse_response

    case response.error_code do
      :no_error -> {response, %{state | consumer_metadata: response, correlation_id: state.correlation_id + 1}}
      _ -> :timer.sleep(400)
        update_consumer_metadata(%{state | correlation_id: state.correlation_id + 1}, retry - 1, response.error_code)
    end
  end

  defp updated_broker_for_topic(state, partition, topic) do
    case MetadataResponse.broker_for_topic(state.metadata, state.brokers, topic, partition) do
      nil    ->
        updated_state = update_metadata(state)
        {MetadataResponse.broker_for_topic(updated_state.metadata, updated_state.brokers, topic, partition), updated_state}
      broker -> {broker, state}
    end
  end

  defp fetch(fetch_request, state) do
    true = consumer_group_if_auto_commit?(fetch_request.auto_commit, state)
    fetch_data = Fetch.create_request(%FetchRequest{
      fetch_request |
      client_id: @client_id,
      correlation_id: state.correlation_id,
    })
    {broker, state} = updated_broker_for_topic(state, fetch_request.partition, fetch_request.topic)

    case broker do
      nil ->
        Logger.log(:error, "Leader for topic #{fetch_request.topic} is not available")
        {:topic_not_found, state}
      _ ->
        response = broker
          |> NetworkClient.send_sync_request(fetch_data, state.sync_timeout)
          |> Fetch.parse_response
        state = %{state | correlation_id: state.correlation_id + 1}
        last_offset = response |> hd |> Map.get(:partitions) |> hd |> Map.get(:last_offset)
        if last_offset != nil && fetch_request.auto_commit do
          offset_commit_request = %OffsetCommit.Request{
            topic: fetch_request.topic,
            offset: last_offset,
            partition: fetch_request.partition,
            consumer_group: state.consumer_group}
          {_, state} = offset_commit(state, offset_commit_request)
          {response, state}
        else
          {response, state}
        end
    end
  end

  defp offset_commit(state, offset_commit_request) do
    {broker, state} = broker_for_consumer_group_with_update(state, true)

    # if the request has a specific consumer group, use that
    # otherwise use the worker's consumer group
    consumer_group = offset_commit_request.consumer_group || state.consumer_group
    offset_commit_request = %{offset_commit_request | consumer_group: consumer_group}

    offset_commit_request_payload = OffsetCommit.create_request(state.correlation_id, @client_id, offset_commit_request)
    response = broker
      |> NetworkClient.send_sync_request(offset_commit_request_payload, state.sync_timeout)
      |> OffsetCommit.parse_response

    {response, %{state | correlation_id: state.correlation_id + 1}}
  end

  defp broker_for_consumer_group(state) do
    ConsumerMetadataResponse.broker_for_consumer_group(state.brokers, state.consumer_metadata)
  end

  # refactored from two versions, one that used the first broker as valid answer, hence
  # the optional extra flag to do that. Wraps broker_for_consumer_group with an update
  # call if no broker was found.
  defp broker_for_consumer_group_with_update(state, use_first_as_default \\ false) do
    case broker_for_consumer_group(state) do
      nil ->
        {_, updated_state} = update_consumer_metadata(state)
        default_broker = if use_first_as_default, do: hd(state.brokers), else: nil
        {broker_for_consumer_group(updated_state) || default_broker, updated_state}
      broker ->
        {broker, state}
    end
  end

  # note within the genserver state, we've already validated the
  # consumer group, so it can only be either :no_consumer_group or a
  # valid binary consumer group name
  def consumer_group?(%State{consumer_group: :no_consumer_group}), do: false
  def consumer_group?(_), do: true

  def consumer_group_if_auto_commit?(true, state) do
    consumer_group?(state)
  end
  def consumer_group_if_auto_commit?(false, _state) do
    true
  end

  defp first_broker_response(request, state) do
    first_broker_response(request, state.brokers, state.sync_timeout)
  end
end
