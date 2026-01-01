defmodule Sprites do
  @moduledoc """
  Elixir SDK for Sprites - remote code container runtime.

  Mirrors Elixir's native process APIs (`System.cmd/3`, `Port` operations).

  ## Quick Start

      # Create a client
      client = Sprites.new(token, base_url: "https://api.sprites.dev")

      # Get a sprite handle
      sprite = Sprites.sprite(client, "my-sprite")

      # System.cmd-like interface (blocking)
      {output, exit_code} = Sprites.cmd(sprite, "echo", ["hello"])

      # Port-like interface (async, message-based)
      {:ok, command} = Sprites.spawn(sprite, "echo", ["hello"])

      receive do
        {:stdout, ^command, data} -> IO.write(data)
        {:exit, ^command, code} -> IO.puts("Exited with: \#{code}")
      end

  ## Creating and Destroying Sprites

      {:ok, sprite} = Sprites.create(client, "new-sprite")
      :ok = Sprites.destroy(sprite)
  """

  alias Sprites.{Client, Sprite, Command}

  @type client :: Client.t()
  @type sprite :: Sprite.t()
  @type command :: Command.t()

  @doc """
  Creates a new Sprites client.

  ## Options

    * `:base_url` - API base URL (default: "https://api.sprites.dev")
    * `:timeout` - HTTP timeout in milliseconds (default: 30_000)

  ## Examples

      client = Sprites.new("my-token")
      client = Sprites.new("my-token", base_url: "https://custom.api.dev")
  """
  @spec new(String.t(), keyword()) :: client()
  def new(token, opts \\ []) do
    Client.new(token, opts)
  end

  @doc """
  Returns a sprite handle for the given name.

  This does not create or verify the sprite exists - it just returns
  a handle that can be used for operations.

  ## Examples

      sprite = Sprites.sprite(client, "my-sprite")
  """
  @spec sprite(client(), String.t()) :: sprite()
  def sprite(client, name) do
    Sprite.new(client, name)
  end

  @doc """
  Creates a new sprite via the API.

  ## Options

    * `:config` - Sprite configuration map

  ## Examples

      {:ok, sprite} = Sprites.create(client, "my-sprite")
  """
  @spec create(client(), String.t(), keyword()) :: {:ok, sprite()} | {:error, term()}
  def create(client, name, opts \\ []) do
    Client.create_sprite(client, name, opts)
  end

  @doc """
  Destroys a sprite.

  ## Examples

      :ok = Sprites.destroy(sprite)
  """
  @spec destroy(sprite()) :: :ok | {:error, term()}
  def destroy(sprite) do
    Sprite.destroy(sprite)
  end

  @doc """
  Executes a command synchronously, similar to `System.cmd/3`.

  Returns `{output, exit_code}` where output is a binary containing
  the combined stdout (and optionally stderr).

  ## Options

    * `:env` - Environment variables as a list of `{key, value}` tuples
    * `:dir` - Working directory
    * `:timeout` - Command timeout in milliseconds
    * `:stderr_to_stdout` - Redirect stderr to stdout (default: false)
    * `:tty` - Allocate a TTY (default: false)
    * `:tty_rows` - TTY rows (default: 24)
    * `:tty_cols` - TTY columns (default: 80)

  ## Examples

      {output, 0} = Sprites.cmd(sprite, "echo", ["hello"])
      {output, code} = Sprites.cmd(sprite, "ls", ["-la"], dir: "/app")
  """
  @spec cmd(sprite(), String.t(), [String.t()], keyword()) :: {binary(), non_neg_integer()}
  def cmd(sprite, command, args \\ [], opts \\ []) do
    Command.run(sprite, command, args, opts)
  end

  @doc """
  Spawns an async command, similar to `Port.open/2`.

  Returns `{:ok, command}` where command is a handle for the running process.
  Messages are sent to the calling process (or the process specified via `:owner`):

    * `{:stdout, command, data}` - stdout data
    * `{:stderr, command, data}` - stderr data
    * `{:exit, command, exit_code}` - command exited
    * `{:error, command, reason}` - error occurred

  ## Options

    * `:owner` - Process to receive messages (default: `self()`)
    * `:env` - Environment variables as a list of `{key, value}` tuples
    * `:dir` - Working directory
    * `:tty` - Allocate a TTY (default: false)
    * `:tty_rows` - TTY rows (default: 24)
    * `:tty_cols` - TTY columns (default: 80)

  ## Examples

      {:ok, cmd} = Sprites.spawn(sprite, "bash", ["-i"], tty: true)

      receive do
        {:stdout, ^cmd, data} -> IO.write(data)
        {:exit, ^cmd, code} -> IO.puts("Done: \#{code}")
      end
  """
  @spec spawn(sprite(), String.t(), [String.t()], keyword()) ::
          {:ok, command()} | {:error, term()}
  def spawn(sprite, command, args \\ [], opts \\ []) do
    Command.start(sprite, command, args, opts)
  end

  @doc """
  Writes data to stdin of a running command.

  ## Examples

      Sprites.write(command, "hello\\n")
  """
  @spec write(command(), iodata()) :: :ok | {:error, term()}
  def write(command, data) do
    Command.write_stdin(command, data)
  end

  @doc """
  Closes stdin of a running command (sends EOF).

  ## Examples

      Sprites.close_stdin(command)
  """
  @spec close_stdin(command()) :: :ok
  def close_stdin(command) do
    Command.close_stdin(command)
  end

  @doc """
  Waits for a command to complete.

  Returns `{:ok, exit_code}` when the command exits.

  ## Examples

      {:ok, 0} = Sprites.await(command)
      {:ok, code} = Sprites.await(command, 30_000)
  """
  @spec await(command(), timeout()) :: {:ok, non_neg_integer()} | {:error, term()}
  def await(command, timeout \\ :infinity) do
    Command.await(command, timeout)
  end

  @doc """
  Resizes the TTY of a running command.

  Only works if the command was started with `tty: true`.

  ## Examples

      Sprites.resize(command, 40, 120)
  """
  @spec resize(command(), pos_integer(), pos_integer()) :: :ok
  def resize(command, rows, cols) do
    Command.resize(command, rows, cols)
  end

  @doc """
  Returns a Stream that emits command output.

  Useful for processing command output lazily.

  ## Examples

      sprite
      |> Sprites.stream("tail", ["-f", "/var/log/app.log"])
      |> Stream.each(&IO.write/1)
      |> Stream.run()
  """
  @spec stream(sprite(), String.t(), [String.t()], keyword()) :: Enumerable.t()
  def stream(sprite, command, args \\ [], opts \\ []) do
    Sprites.Stream.new(sprite, command, args, opts)
  end
end
