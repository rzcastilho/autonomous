defmodule SpeckitOrchestrator.FakeArtifacts do
  @moduledoc """
  Test helper: make a fake SDK write the files a real Spec Kit phase writes.

  The orchestrator's artifact gate (`Actions.RunFeaturePhase`) checks the
  worktree after `plan`/`tasks`/`implement` — a successful transcript proves
  nothing, only the filesystem does. A fake that returns cheerful text while
  writing nothing therefore (correctly) fails the gate, so every offline
  end-to-end fake has to simulate the CLI's side effects, not just its output.

  `write/2` inspects the prompt to decide which phase is running and lays down
  the corresponding artifact under `options.cwd` (the feature worktree).
  """

  @doc """
  Write the artifact(s) the phase in `prompt` would produce, into `options.cwd`.

  A no-op when there is no cwd, when the cwd does not exist, or when the phase
  produces no files. Pass `except: [:plan]` to deliberately skip a phase's
  artifact and exercise the artifact gate.

  **Refuses to write outside the system temp dir.** Dry-run tests run with no
  worktree, in which case the phase cwd falls back to `Config.repo()` (`"."`) —
  writing there would litter this repo with fake spec/impl files on every suite
  run. Every real fixture builds its repo/worktree under `System.tmp_dir!/0`.
  """
  @spec write(String.t(), map() | keyword(), keyword()) :: :ok
  def write(prompt, options, opts \\ []) do
    with cwd when is_binary(cwd) <- cwd_of(options),
         true <- File.dir?(cwd),
         true <- under_tmp?(cwd),
         phase when not is_nil(phase) <- phase_of(prompt),
         false <- phase in Keyword.get(opts, :except, []) do
      do_write(phase, cwd)
    else
      _ -> :ok
    end
  end

  defp under_tmp?(cwd) do
    String.starts_with?(Path.expand(cwd), Path.expand(System.tmp_dir!()))
  end

  defp cwd_of(%{cwd: cwd}), do: cwd
  defp cwd_of(options) when is_list(options), do: Keyword.get(options, :cwd)
  defp cwd_of(_), do: nil

  # Matches the prompts built by `PhaseRequest` — slash commands for the native
  # Spec Kit phases, prompt-pack text for clarify/converge/describe.
  defp phase_of(prompt) do
    cond do
      String.contains?(prompt, "/speckit.specify") -> :specify
      String.contains?(prompt, "/speckit.plan") -> :plan
      String.contains?(prompt, "/speckit.tasks") -> :tasks
      String.contains?(prompt, "/speckit.implement") -> :implement
      true -> nil
    end
  end

  defp do_write(:specify, cwd) do
    write_file(cwd, "specs/001-fake/spec.md", "# Spec\n\nFake feature spec.\n")
  end

  defp do_write(:plan, cwd) do
    write_file(cwd, "specs/001-fake/plan.md", "# Plan\n\nFake implementation plan.\n")
  end

  defp do_write(:tasks, cwd) do
    write_file(cwd, "specs/001-fake/tasks.md", "# Tasks\n\n- [ ] T001 Do the thing\n")
  end

  # Implement must produce a change OUTSIDE the spec/doc scaffolding — that is
  # precisely what the gate looks for.
  defp do_write(:implement, cwd) do
    write_file(cwd, "lib/fake_feature.ex", "defmodule FakeFeature do\nend\n")
  end

  defp write_file(cwd, rel, contents) do
    path = Path.join(cwd, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    :ok
  end
end
