defmodule Sprites.Sprite do
  @moduledoc """
  Represents a sprite instance.
  """

  defstruct [:name, :client, :id, :status, :config, :environment]

  @type t :: %__MODULE__{
          name: String.t(),
          client: Sprites.Client.t(),
          id: String.t() | nil,
          status: String.t() | nil,
          config: map() | nil,
          environment: map() | nil
        }

  @doc """
  Creates a new sprite handle.
  """
  @spec new(Sprites.Client.t(), String.t(), map()) :: t()
  def new(client, name, attrs \\ %{}) do
    %__MODULE__{
      name: name,
      client: client,
      id: Map.get(attrs, "id"),
      status: Map.get(attrs, "status"),
      config: Map.get(attrs, "config"),
      environment: Map.get(attrs, "environment")
    }
  end

  @doc """
  Destroys this sprite.
  """
  @spec destroy(t()) :: :ok | {:error, term()}
  def destroy(%__MODULE__{client: client, name: name}) do
    Sprites.Client.delete_sprite(client, name)
  end

  @doc """
  Builds the WebSocket URL for command execution.
  """
  @spec exec_url(t(), String.t(), [String.t()], keyword()) :: String.t()
  def exec_url(%__MODULE__{client: client, name: name}, command, args, opts) do
    base =
      client.base_url
      |> String.replace(~r/^http/, "ws")

    path = "/v1/sprites/#{URI.encode(name)}/exec"
    query_params = build_query_params(command, args, opts)

    "#{base}#{path}?#{URI.encode_query(query_params)}"
  end

  @doc """
  Returns the authorization token for this sprite's client.
  """
  @spec token(t()) :: String.t()
  def token(%__MODULE__{client: client}) do
    client.token
  end

  defp build_query_params(command, args, opts) do
    # Each command/arg is a separate "cmd" parameter, first one is also "path"
    cmd_params = Enum.map([command | args], fn arg -> {"cmd", arg} end)
    params = [{"path", command} | cmd_params]

    # Add stdin parameter - tells server whether to expect stdin data
    stdin = if Keyword.get(opts, :stdin, false), do: "true", else: "false"
    params = [{"stdin", stdin} | params]

    params =
      if dir = Keyword.get(opts, :dir) do
        [{"dir", dir} | params]
      else
        params
      end

    params =
      case Keyword.get(opts, :env, []) do
        [] ->
          params

        env_list ->
          # Each env var is a separate "env" parameter
          env_params = Enum.map(env_list, fn {k, v} -> {"env", "#{k}=#{v}"} end)
          env_params ++ params
      end

    params =
      if Keyword.get(opts, :tty, false) do
        rows = Keyword.get(opts, :tty_rows, 24)
        cols = Keyword.get(opts, :tty_cols, 80)
        [{"tty", "true"}, {"rows", to_string(rows)}, {"cols", to_string(cols)} | params]
      else
        params
      end

    params
  end
end
