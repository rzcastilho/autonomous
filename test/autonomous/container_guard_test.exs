defmodule Autonomous.ContainerGuardTest do
  # Not async: containerized?/0 reads global app env and the OS env.
  use ExUnit.Case, async: false

  alias Autonomous.ContainerGuard

  describe "decide/2" do
    test "container not required (test config) accepts any marker" do
      for marker <- ["1", "0", "", nil] do
        assert :ok = ContainerGuard.decide(marker, false)
      end
    end

    test "required and marker \"1\" passes" do
      assert :ok = ContainerGuard.decide("1", true)
    end

    test "required and any other marker refuses" do
      for marker <- ["0", "", "true", "yes", nil] do
        assert {:error, :not_in_container} = ContainerGuard.decide(marker, true)
      end
    end
  end

  describe "containerized?/0" do
    setup do
      old_env = System.get_env("AUTONOMOUS_CONTAINER")
      old_req = Application.fetch_env(:autonomous, :require_container)

      on_exit(fn ->
        if old_env,
          do: System.put_env("AUTONOMOUS_CONTAINER", old_env),
          else: System.delete_env("AUTONOMOUS_CONTAINER")

        case old_req do
          {:ok, v} -> Application.put_env(:autonomous, :require_container, v)
          :error -> Application.delete_env(:autonomous, :require_container)
        end
      end)
    end

    test "truth table" do
      table = [
        {"1", true, true},
        {"1", false, false},
        {nil, true, false},
        {nil, false, false},
        {"0", true, false}
      ]

      for {marker, required, expected} <- table do
        if marker,
          do: System.put_env("AUTONOMOUS_CONTAINER", marker),
          else: System.delete_env("AUTONOMOUS_CONTAINER")

        Application.put_env(:autonomous, :require_container, required)

        assert ContainerGuard.containerized?() == expected,
               "marker=#{inspect(marker)} required=#{required}"
      end
    end

    test "the test config disables the guard, so the suite behaves the same in the image" do
      System.put_env("AUTONOMOUS_CONTAINER", "1")
      Application.put_env(:autonomous, :require_container, false)

      refute ContainerGuard.containerized?()
      assert :ok = ContainerGuard.check!()
    end

    test "check!/0 raises the contract message when required and the marker is missing" do
      System.delete_env("AUTONOMOUS_CONTAINER")
      Application.put_env(:autonomous, :require_container, true)

      error = assert_raise RuntimeError, fn -> ContainerGuard.check!() end
      assert error.message == ContainerGuard.refusal_message()
    end
  end

  test "refusal message names the wrapper commands and the non-security caveat" do
    msg = ContainerGuard.refusal_message()

    assert msg =~
             "autonomous refuses to start outside its container (AUTONOMOUS_CONTAINER is not set)."

    assert msg =~ "scripts/autonomous shell   --target <repo>"
    assert msg =~ "scripts/autonomous console --target <repo>"
    assert msg =~ "scripts/autonomous release --target <repo>"
    assert msg =~ "`mix compile` and `mix test` still work on the host."
    assert msg =~ "it is not a security boundary."
  end
end
