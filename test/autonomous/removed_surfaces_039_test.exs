defmodule Autonomous.RemovedSurfaces039Test do
  @moduledoc """
  039 (T054, SC-002): neither removed setting survives as a surface — not as a
  captured run setting (`RunContext.keys/0`), not as a `Config` accessor, not
  as a console form field (Configuration, Trigger), not as a topbar gauge or
  chip.
  """

  use Autonomous.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Autonomous.{Config, RunContext}

  @endpoint Autonomous.Web.Endpoint
  @removed ~r/budget|containment|breaker/i

  test "RunContext captures neither setting" do
    for key <- RunContext.keys(), do: refute(Atom.to_string(key) =~ @removed)
  end

  test "Config exports no budget or profile accessor" do
    for {name, _arity} <- Config.__info__(:functions),
        do: refute(Atom.to_string(name) =~ @removed)
  end

  test "Ledger exposes no budget, reserve or breaker API" do
    for {name, _arity} <- Autonomous.Ledger.__info__(:functions),
        do: refute(Atom.to_string(name) =~ ~r/budget|reserve|breaker/)

    refute Map.has_key?(Autonomous.Ledger.snapshot(), :budget)
  end

  test "the Containment module is gone" do
    refute Code.ensure_loaded?(Autonomous.Containment)
  end

  for path <- ["/config", "/trigger"] do
    test "#{path} has no budget or profile field and no gauge/breaker/containment chip" do
      {:ok, _view, html} = live(build_conn(), unquote(path))

      names =
        ~r/<(?:input|select|textarea)\b[^>]*\bname="([^"]+)"/
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()

      assert names != [], "expected #{unquote(path)} to render form fields"
      for name <- names, do: refute(name =~ @removed)

      refute html =~ ~r/cost-gauge|breaker-chip|containment-chip|data-containment/
    end
  end
end
