defmodule Autonomous.Web.ConfigLiveVolumesTest do
  # Mutates the process env (AUTONOMOUS_VOLUMES).
  use Autonomous.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Autonomous.Web.Endpoint

  setup do
    prior = System.get_env("AUTONOMOUS_VOLUMES")

    on_exit(fn ->
      if prior,
        do: System.put_env("AUTONOMOUS_VOLUMES", prior),
        else: System.delete_env("AUTONOMOUS_VOLUMES")
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp apply_volumes(paths) do
    System.put_env(
      "AUTONOMOUS_VOLUMES",
      Jason.encode!(%{
        version: 1,
        declaration: "/cfg/targets/x/volumes.toml",
        volumes:
          for {name, path} <- paths do
            %{
              name: name,
              path: path,
              env: [["BUILD_DIR", path <> "/b"]],
              path_dirs: [path <> "/bin"]
            }
          end
      })
    )
  end

  @tag :tmp_dir
  test "lists applied volumes and measures usage", %{conn: conn, tmp_dir: dir} do
    File.write!(Path.join(dir, "f"), String.duplicate("x", 8192))
    apply_volumes([{"cache", dir}, {"gone", Path.join(dir, "missing")}])

    {:ok, view, _html} = live(conn, "/config")

    assert has_element?(view, "[data-volumes]")
    assert has_element?(view, ~s([data-volume="cache"]))
    assert has_element?(view, ~s([data-volume="gone"]))
    assert render(view) =~ "as applied at start"
    assert render(view) =~ "BUILD_DIR=#{dir}/b"

    html = render_async(view, 3_000)
    assert html =~ ~s(data-volume-usage="known")
    assert html =~ ~s(data-volume-usage="unknown")
    assert html =~ "unknown (not mounted)"
  end

  test "no declaration leaves the page without the group", %{conn: conn} do
    System.delete_env("AUTONOMOUS_VOLUMES")
    {:ok, view, html} = live(conn, "/config")
    refute html =~ "data-volumes"
    refute has_element?(view, "[data-volumes]")
  end

  test "malformed value renders a refusal", %{conn: conn} do
    System.put_env("AUTONOMOUS_VOLUMES", "{nope")
    {:ok, view, html} = live(conn, "/config")
    assert has_element?(view, "[data-volumes]")
    assert html =~ "AUTONOMOUS_VOLUMES unreadable"
  end

  @tag :tmp_dir
  test "reload re-measures", %{conn: conn, tmp_dir: dir} do
    apply_volumes([{"cache", dir}])
    {:ok, view, _} = live(conn, "/config")
    assert render_async(view, 3_000) =~ ~s(data-volume-usage="known")

    {:ok, view2, html2} = live(conn, "/config")
    assert html2 =~ ~s(data-volume-usage="measuring")
    assert render_async(view2, 3_000) =~ ~s(data-volume-usage="known")
  end
end
