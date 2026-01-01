defmodule Sprites.Error do
  @moduledoc """
  Error types for the Sprites SDK.
  """

  defmodule APIError do
    @moduledoc "Raised when the API returns an error response."
    defexception [:status, :message, :body]

    @impl true
    def message(%{status: status, message: msg}) do
      "API error (#{status}): #{msg}"
    end
  end

  defmodule CommandError do
    @moduledoc "Raised when a command fails with non-zero exit code."
    defexception [:exit_code, :stderr]

    @impl true
    def message(%{exit_code: code}) do
      "Command exited with code #{code}"
    end
  end

  defmodule ConnectionError do
    @moduledoc "Raised when WebSocket connection fails."
    defexception [:reason]

    @impl true
    def message(%{reason: reason}) do
      "WebSocket connection failed: #{inspect(reason)}"
    end
  end

  defmodule TimeoutError do
    @moduledoc "Raised when an operation times out."
    defexception [:timeout]

    @impl true
    def message(%{timeout: timeout}) do
      "Operation timed out after #{timeout}ms"
    end
  end
end
