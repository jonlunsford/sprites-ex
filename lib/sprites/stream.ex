defmodule Sprites.Stream do
  @moduledoc """
  Provides an Elixir Stream-based interface for command output.

  This allows processing command output lazily and composing with
  other Stream operations.

  ## Example

      sprite
      |> Sprites.stream("tail", ["-f", "/var/log/app.log"])
      |> Stream.filter(&String.contains?(&1, "ERROR"))
      |> Stream.each(&Logger.error/1)
      |> Stream.run()
  """

  @doc """
  Creates a new stream that emits command output chunks.

  The stream will emit stdout data as binary chunks.
  Stderr is not included in the stream (use `Sprites.spawn/4` for full control).

  ## Options

  Same as `Sprites.spawn/4`.
  """
  @spec new(Sprites.Sprite.t(), String.t(), [String.t()], keyword()) :: Enumerable.t()
  def new(sprite, command, args, opts) do
    Stream.resource(
      fn -> start_command(sprite, command, args, opts) end,
      &next_chunk/1,
      &cleanup/1
    )
  end

  defp start_command(sprite, command, args, opts) do
    case Sprites.Command.start(sprite, command, args, opts) do
      {:ok, cmd} -> {:running, cmd}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_chunk({:error, reason}) do
    raise "Stream error: #{inspect(reason)}"
  end

  defp next_chunk({:done, cmd}) do
    {:halt, {:done, cmd}}
  end

  defp next_chunk({:running, cmd}) do
    ref = cmd.ref

    receive do
      {:stdout, %{ref: ^ref}, data} ->
        {[data], {:running, cmd}}

      {:stderr, %{ref: ^ref}, _data} ->
        # Skip stderr in stream mode
        {[], {:running, cmd}}

      {:exit, %{ref: ^ref}, _code} ->
        {:halt, {:done, cmd}}

      {:error, %{ref: ^ref}, reason} ->
        raise "Stream error: #{inspect(reason)}"
    after
      60_000 ->
        {:halt, {:done, cmd}}
    end
  end

  defp cleanup({:done, _cmd}) do
    :ok
  end

  defp cleanup({:running, _cmd}) do
    # Command may still be running, but we're done consuming
    :ok
  end

  defp cleanup({:error, _reason}) do
    :ok
  end
end
