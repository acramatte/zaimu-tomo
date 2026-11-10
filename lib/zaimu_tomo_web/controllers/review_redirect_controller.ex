defmodule ZaimuTomoWeb.ReviewRedirectController do
  @moduledoc """
  Redirects the retired review pages to the invoice page that replaced them.
  """
  use ZaimuTomoWeb, :controller

  alias ZaimuTomo.Review

  def index(conn, _params), do: redirect(conn, to: ~p"/documents?tab=needs_action")

  def show(conn, %{"id" => id}) do
    case Review.get_review_decision(id, conn.assigns.current_scope.user.id) do
      {:ok, decision} ->
        redirect(conn, to: ~p"/documents/#{decision.extracted_content.document_id}")

      {:error, reason} ->
        conn |> put_flash(:error, reason) |> redirect(to: ~p"/documents")
    end
  end
end
