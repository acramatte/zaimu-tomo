defmodule LedgemechanicusWeb.DocumentLive.Index do
  use LedgemechanicusWeb, :live_view

  alias Ledgemechanicus.Documents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Listing Documents
        <:actions>
          <.button variant="primary" navigate={~p"/documents/new"}>
            <.icon name="hero-plus" /> New Document
          </.button>
        </:actions>
      </.header>

      <.table
        id="documents"
        rows={@streams.documents}
        row_click={fn {_id, document} -> JS.navigate(~p"/documents/#{document}") end}
      >
        <:col :let={{_id, document}} label="Filename">{document.filename}</:col>
        <:col :let={{_id, document}} label="Filepath">{document.filepath}</:col>
        <:action :let={{_id, document}}>
          <div class="sr-only">
            <.link navigate={~p"/documents/#{document}"}>Show</.link>
          </div>
          <.link navigate={~p"/documents/#{document}/edit"}>Edit</.link>
        </:action>
        <:action :let={{id, document}}>
          <.link
            phx-click={JS.push("delete", value: %{id: document.id}) |> hide("##{id}")}
            data-confirm="Are you sure?"
          >
            Delete
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Documents.subscribe_documents(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:page_title, "Listing Documents")
     |> stream(:documents, list_documents(socket.assigns.current_scope))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    document = Documents.get_document!(socket.assigns.current_scope, id)
    {:ok, _} = Documents.delete_document(socket.assigns.current_scope, document)

    {:noreply, stream_delete(socket, :documents, document)}
  end

  @impl true
  def handle_info({type, %Ledgemechanicus.Documents.Document{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply, stream(socket, :documents, list_documents(socket.assigns.current_scope), reset: true)}
  end

  defp list_documents(current_scope) do
    Documents.list_documents(current_scope)
  end
end
