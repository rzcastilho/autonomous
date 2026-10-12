defmodule Autonomous.CredentialMaskTest do
  use ExUnit.Case, async: true

  alias Autonomous.CredentialMask

  test "names/0 is the explicit list" do
    assert CredentialMask.names() ==
             ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN GH_TOKEN GITHUB_TOKEN)
  end

  describe "pairs/1" do
    test "drops short and unset values, longest first" do
      env = %{
        "GH_TOKEN" => "ghp_12345678",
        "ANTHROPIC_API_KEY" => "short",
        "GITHUB_TOKEN" => "ghp_12345678901234"
      }

      assert CredentialMask.pairs(&Map.get(env, &1)) ==
               [{"GITHUB_TOKEN", "ghp_12345678901234"}, {"GH_TOKEN", "ghp_12345678"}]
    end

    test "reads the real environment by default" do
      assert is_list(CredentialMask.pairs())
    end
  end

  describe "mask/2" do
    @pairs [{"GITHUB_TOKEN", "ghp_12345678901234"}, {"GH_TOKEN", "ghp_12345678"}]

    test "replaces every occurrence, longest first, across nesting" do
      term = %{
        "ghp_12345678" => ["x ghp_12345678901234 y", %{"k" => "ghp_12345678 ghp_12345678"}],
        n: 3
      }

      assert CredentialMask.mask(term, @pairs) == %{
               "[masked:GH_TOKEN]" => [
                 "x [masked:GITHUB_TOKEN] y",
                 %{"k" => "[masked:GH_TOKEN] [masked:GH_TOKEN]"}
               ],
               n: 3
             }
    end

    test "non-strings untouched; no pairs is identity" do
      assert CredentialMask.mask({:a, 1, nil, 2.0}, @pairs) == {:a, 1, nil, 2.0}
      assert CredentialMask.mask("ghp_12345678", []) == "ghp_12345678"
    end
  end
end
