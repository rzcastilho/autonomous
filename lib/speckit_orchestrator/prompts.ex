defmodule SpeckitOrchestrator.Prompts do
  @moduledoc """
  Versioned prompt packs, embedded from `priv/prompts/*.md` at compile time so
  they travel with the release and need no runtime `priv` path resolution.
  """

  @prompts_dir Path.join([__DIR__, "..", "..", "priv", "prompts"])

  for name <- ~w(clarify analyze converge) do
    path = Path.join(@prompts_dir, "#{name}.md")
    @external_resource path
    contents = File.read!(path)
    def load(unquote(name)), do: unquote(contents)
  end

  def load(other), do: raise(ArgumentError, "no prompt pack: #{inspect(other)}")
end
