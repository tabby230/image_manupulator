defmodule ImageManipulatorWeb.PageControllerTest do
  use ImageManipulatorWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "ImageManipulator"
    assert html =~ "LiveView image studio"
    assert html =~ "studio"
    assert html =~ "appbar"
  end
end
