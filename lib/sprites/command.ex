defmodule Sprites.Command do
  @moduledoc """
  Represents a running command on a sprite.

  Uses a GenServer to manage the WebSocket connection.
  Messages are sent to the owner process:

    * `{:stdout, command, data}` - stdout data received
    * `{:stderr, command, data}` - stderr data received
    * `{:exit, command, exit_code}` - command completed
    * `{:error, command, reason}` - error occurred
  """

  use GenServer
  require Logger

  alias Sprites.{Sprite, Protocol}

  defstruct [:ref, :pid, :sprite, :owner, :tty_mode]

  @type t :: %__MODULE__{
          ref: reference(),
          pid: pid(),
          sprite: Sprite.t(),
          owner: pid(),
          tty_mode: boolean()
        }

  # Client API

  @doc """
  Starts a command asynchronously.
  """
  @spec start(Sprite.t(), String.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def start(sprite, command, args, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    tty_mode = Keyword.get(opts, :tty, false)

    ref = make_ref()

    init_args = %{
      sprite: sprite,
      command: command,
      args: args,
      opts: opts,
      owner: owner,
      ref: ref
    }

    case GenServer.start(__MODULE__, init_args) do
      {:ok, pid} ->
        {:ok,
         %__MODULE__{
           ref: ref,
           pid: pid,
           sprite: sprite,
           owner: owner,
           tty_mode: tty_mode
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs a command synchronously (blocking).
  Returns `{output, exit_code}`.
  """
  @spec run(Sprite.t(), String.t(), [String.t()], keyword()) :: {binary(), non_neg_integer()}
  def run(sprite, command, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, false)

    case start(sprite, command, args, opts) do
      {:ok, cmd} ->
        collect_output(cmd, "", stderr_to_stdout, timeout)

      {:error, reason} ->
        raise "Failed to start command: #{inspect(reason)}"
    end
  end

  @doc """
  Writes to stdin.
  """
  @spec write_stdin(t(), iodata()) :: :ok | {:error, term()}
  def write_stdin(%__MODULE__{pid: pid}, data) do
    GenServer.call(pid, {:write_stdin, data})
  end

  @doc """
  Closes stdin (sends EOF).
  """
  @spec close_stdin(t()) :: :ok
  def close_stdin(%__MODULE__{pid: pid}) do
    GenServer.cast(pid, :close_stdin)
  end

  @doc """
  Waits for command completion.
  """
  @spec await(t(), timeout()) :: {:ok, non_neg_integer()} | {:error, term()}
  def await(%__MODULE__{ref: ref}, timeout \\ :infinity) do
    receive do
      {:exit, %{ref: ^ref}, exit_code} -> {:ok, exit_code}
      {:error, %{ref: ^ref}, reason} -> {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Resizes the TTY.
  """
  @spec resize(t(), pos_integer(), pos_integer()) :: :ok
  def resize(%__MODULE__{pid: pid}, rows, cols) do
    GenServer.cast(pid, {:resize, rows, cols})
  end

  # GenServer callbacks

  @impl true
  def init(%{sprite: sprite, command: command, args: args, opts: opts, owner: owner, ref: ref}) do
    url = Sprite.exec_url(sprite, command, args, opts)
    tty_mode = Keyword.get(opts, :tty, false)
    token = Sprite.token(sprite)

    state = %{
      owner: owner,
      ref: ref,
      tty_mode: tty_mode,
      conn: nil,
      websocket: nil,
      request_ref: nil,
      exit_code: nil,
      buffer: <<>>
    }

    # Connect synchronously in init to fail fast
    case do_connect(url, token) do
      {:ok, conn, ws_ref} ->
        {:ok, %{state | conn: conn, request_ref: ws_ref}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp do_connect(url, token) do
    uri = URI.parse(url)
    ws_scheme = if uri.scheme == "wss", do: :wss, else: :ws
    http_scheme = if uri.scheme == "wss", do: :https, else: :http
    port = uri.port || if(http_scheme == :https, do: 443, else: 80)

    case Mint.HTTP.connect(http_scheme, uri.host, port, protocols: [:http1]) do
      {:ok, conn} ->
        path = "#{uri.path}?#{uri.query || ""}"
        headers = [{"authorization", "Bearer #{token}"}]

        case Mint.WebSocket.upgrade(ws_scheme, conn, path, headers) do
          {:ok, conn, ref} ->
            {:ok, conn, ref}

          {:error, _conn, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def handle_info(message, %{conn: conn, request_ref: ref, websocket: nil} = state)
      when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        handle_upgrade_responses(responses, ref, state)

      {:error, _conn, reason, _responses} ->
        send(state.owner, {:error, %{ref: state.ref}, reason})
        {:stop, :normal, state}
    end
  end

  def handle_info(message, %{conn: conn, websocket: websocket} = state)
      when conn != nil and websocket != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        handle_websocket_responses(responses, state)

      {:error, _conn, reason, _responses} ->
        send(state.owner, {:error, %{ref: state.ref}, reason})
        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, _}, state), do: handle_connection_closed(state)
  def handle_info({:ssl_closed, _}, state), do: handle_connection_closed(state)
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:write_stdin, data}, _from, %{conn: conn, websocket: websocket, tty_mode: tty_mode} = state)
      when websocket != nil do
    frame_data = Protocol.encode_stdin(data, tty_mode)

    case Mint.WebSocket.encode(websocket, {:binary, frame_data}) do
      {:ok, websocket, data_to_send} ->
        case Mint.HTTP.stream_request_body(conn, state.request_ref, data_to_send) do
          {:ok, conn} ->
            {:reply, :ok, %{state | conn: conn, websocket: websocket}}

          {:error, conn, reason} ->
            {:reply, {:error, reason}, %{state | conn: conn}}
        end

      {:error, websocket, reason} ->
        {:reply, {:error, reason}, %{state | websocket: websocket}}
    end
  end

  def handle_call({:write_stdin, _data}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_cast(:close_stdin, %{conn: conn, websocket: websocket, tty_mode: false} = state)
      when websocket != nil do
    frame_data = Protocol.encode_stdin_eof()

    case Mint.WebSocket.encode(websocket, {:binary, frame_data}) do
      {:ok, websocket, data_to_send} ->
        case Mint.HTTP.stream_request_body(conn, state.request_ref, data_to_send) do
          {:ok, conn} ->
            {:noreply, %{state | conn: conn, websocket: websocket}}

          {:error, conn, _reason} ->
            {:noreply, %{state | conn: conn}}
        end

      {:error, websocket, _reason} ->
        {:noreply, %{state | websocket: websocket}}
    end
  end

  def handle_cast(:close_stdin, state), do: {:noreply, state}

  def handle_cast({:resize, rows, cols}, %{conn: conn, websocket: websocket, tty_mode: true} = state)
      when websocket != nil do
    message = Jason.encode!(%{type: "resize", rows: rows, cols: cols})

    case Mint.WebSocket.encode(websocket, {:text, message}) do
      {:ok, websocket, data_to_send} ->
        case Mint.HTTP.stream_request_body(conn, state.request_ref, data_to_send) do
          {:ok, conn} ->
            {:noreply, %{state | conn: conn, websocket: websocket}}

          {:error, conn, _reason} ->
            {:noreply, %{state | conn: conn}}
        end

      {:error, websocket, _reason} ->
        {:noreply, %{state | websocket: websocket}}
    end
  end

  def handle_cast({:resize, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when conn != nil do
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private helpers

  defp handle_upgrade_responses(responses, request_ref, state) do
    case find_upgrade_response(responses, request_ref) do
      {:ok, status, headers} when status == 101 ->
        case Mint.WebSocket.new(state.conn, request_ref, status, headers) do
          {:ok, conn, websocket} ->
            {:noreply, %{state | conn: conn, websocket: websocket}}

          {:error, _conn, reason} ->
            send(state.owner, {:error, %{ref: state.ref}, reason})
            {:stop, :normal, state}
        end

      {:ok, status, _headers} ->
        send(state.owner, {:error, %{ref: state.ref}, {:upgrade_failed, status}})
        {:stop, :normal, state}

      :waiting ->
        {:noreply, state}

      {:error, reason} ->
        send(state.owner, {:error, %{ref: state.ref}, reason})
        {:stop, :normal, state}
    end
  end

  defp find_upgrade_response(responses, request_ref) do
    status = Enum.find_value(responses, fn
      {:status, ^request_ref, status} -> status
      _ -> nil
    end)

    headers = Enum.flat_map(responses, fn
      {:headers, ^request_ref, headers} -> headers
      _ -> []
    end)

    done? = Enum.any?(responses, fn
      {:done, ^request_ref} -> true
      _ -> false
    end)

    error = Enum.find_value(responses, fn
      {:error, ^request_ref, reason} -> reason
      _ -> nil
    end)

    cond do
      error != nil -> {:error, error}
      status != nil and done? -> {:ok, status, headers}
      status != nil -> {:ok, status, headers}
      true -> :waiting
    end
  end

  defp handle_websocket_responses(responses, state) do
    Enum.reduce(responses, {:noreply, state}, fn response, {_, acc_state} ->
      case response do
        {:data, _ref, data} ->
          handle_websocket_data(data, acc_state)

        {:done, _ref} ->
          handle_connection_closed(acc_state)

        _ ->
          {:noreply, acc_state}
      end
    end)
  end

  defp handle_websocket_data(data, %{websocket: websocket, buffer: buffer} = state) do
    full_data = buffer <> data

    case Mint.WebSocket.decode(websocket, full_data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket, buffer: <<>>}
        process_frames(frames, state)

      {:error, websocket, reason} ->
        send(state.owner, {:error, %{ref: state.ref}, reason})
        {:stop, :normal, %{state | websocket: websocket}}
    end
  end

  defp process_frames(frames, state) do
    # Process all frames - collect final result
    Enum.reduce(frames, {:noreply, state}, fn frame, {_action, acc_state} ->
      handle_frame(frame, acc_state)
    end)
  end

  defp handle_frame({:binary, data}, %{tty_mode: true, owner: owner, ref: ref} = state) do
    send(owner, {:stdout, %{ref: ref}, data})
    {:noreply, state}
  end

  defp handle_frame({:binary, data}, %{tty_mode: false, owner: owner, ref: ref} = state) do
    case Protocol.decode(data) do
      {:stdout, payload} ->
        send(owner, {:stdout, %{ref: ref}, payload})
        {:noreply, state}

      {:stderr, payload} ->
        send(owner, {:stderr, %{ref: ref}, payload})
        {:noreply, state}

      {:exit, code} ->
        send(owner, {:exit, %{ref: ref}, code})
        {:stop, :normal, %{state | exit_code: code}}

      {:stdin_eof, _} ->
        {:noreply, state}

      {:unknown, _} ->
        {:noreply, state}
    end
  end

  defp handle_frame({:text, json}, %{owner: owner, ref: ref} = state) do
    case Jason.decode(json) do
      {:ok, %{"type" => "port", "port" => port}} ->
        send(owner, {:port, %{ref: ref}, port})
        {:noreply, state}

      {:ok, %{"type" => "exit", "code" => code}} ->
        send(owner, {:exit, %{ref: ref}, code})
        {:stop, :normal, %{state | exit_code: code}}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_frame({:close, _code, _reason}, %{exit_code: nil, owner: owner, ref: ref} = state) do
    send(owner, {:exit, %{ref: ref}, 0})
    {:stop, :normal, state}
  end

  defp handle_frame({:close, _code, _reason}, state) do
    {:stop, :normal, state}
  end

  defp handle_frame(_frame, state) do
    {:noreply, state}
  end

  defp handle_connection_closed(%{exit_code: nil, owner: owner, ref: ref} = state) do
    send(owner, {:error, %{ref: ref}, :connection_closed})
    {:stop, :normal, state}
  end

  defp handle_connection_closed(state) do
    {:stop, :normal, state}
  end

  defp collect_output(cmd, acc, stderr_to_stdout, timeout) do
    ref = cmd.ref

    receive do
      {:stdout, %{ref: ^ref}, data} ->
        collect_output(cmd, acc <> data, stderr_to_stdout, timeout)

      {:stderr, %{ref: ^ref}, data} when stderr_to_stdout ->
        collect_output(cmd, acc <> data, stderr_to_stdout, timeout)

      {:stderr, %{ref: ^ref}, _data} ->
        collect_output(cmd, acc, stderr_to_stdout, timeout)

      {:exit, %{ref: ^ref}, code} ->
        {acc, code}

      {:error, %{ref: ^ref}, reason} ->
        raise "Command failed: #{inspect(reason)}"
    after
      timeout ->
        raise Sprites.Error.TimeoutError, timeout: timeout
    end
  end
end
