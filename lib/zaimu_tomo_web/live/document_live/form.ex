defmodule ZaimuTomoWeb.DocumentLive.Form do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Documents
  alias ZaimuTomo.Documents.Document

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage document records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="document-form" phx-change="validate" phx-submit="save">
        <p class="mt-1 text-sm leading-6 text-gray-500">
          Accepts PDF, JPEG, PNG, WEBP, HEIC, TIFF, DOC, and TXT files.
        </p>
        <div class="px-4 py-6 border-t border-gray-200">
          <div
            phx-drop-target={@uploads.document.ref}
            class="phx-drop-target-active:scale-105 relative block w-full rounded-lg border-2 border-dashed border-gray-300 p-12 text-center hover:border-gray-400 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2"
          >
            <.icon name="hero-cloud-arrow-up" class="size-16 text-gray-400" />
            <div class="mt-4 flex text-sm leading-6 text-gray-500 justify-center">
              <label
                for={@uploads.document.ref}
                class="relative font-semibold text-primary focus-within:outline-none hover:text-gray-400 cursor-pointer"
              >
                <.live_file_input upload={@uploads.document} class="cursor-pointer" />
              </label>
              <p class="pl-1">or drag and drop</p>
            </div>
          </div>
        </div>

        <section>
          <%!-- render each document entry --%>
          <article :for={entry <- @uploads.document.entries} class="upload-entry">
            <%!-- entry.progress will update automatically for in-flight entries --%>
            <progress value={entry.progress} max="100">{entry.progress}% </progress>

            <%!-- a regular click event whose handler will invoke Phoenix.LiveView.cancel_upload/3 --%>
            <button
              type="button"
              phx-click="cancel-upload"
              phx-value-ref={entry.ref}
              aria-label="cancel"
            >
              &times;
            </button>
            <p class="pointer-events-none mt-2 block truncate text-sm font-medium text-gray-900">
              {entry.client_name}
            </p>
            <p class="pointer-events-none block text-sm font-medium text-gray-500">
              {to_megabytes_or_kilobytes(entry.client_size)}
            </p>

            <%!-- Phoenix.Component.upload_errors/2 returns a list of error atoms --%>
            <p
              :for={err <- upload_errors(@uploads.document, entry)}
              role="alert"
              class="alert alert-error"
            >
              {error_to_string(err)}
            </p>
          </article>

          <%!-- Phoenix.Component.upload_errors/1 returns a list of error atoms --%>
          <p :for={err <- upload_errors(@uploads.document)} role="alert" class="alert alert-error">
            {error_to_string(err)}
          </p>
        </section>

        <footer>
          <.button phx-disable-with="Saving..." variant="primary">Save Document</.button>
          <.button navigate={return_path(@current_scope, @return_to, @document)}>Cancel</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     # accept relevant document types supported by our OCR API https://docs.mistral.ai/capabilities/document_ai/basic_ocr#faq
     |> allow_upload(:document,
       accept: ~w(.jpg .jpeg .png .tiff .heic .heif .webp .pdf .docx .odt .txt),
       max_file_size: 20_000_000,
       auto_upload: true,
       chunk_size: 64_000 * 3,
       max_entries: 1
     )
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    document = Documents.get_document!(socket.assigns.current_scope, id)

    socket
    |> assign(:page_title, "Edit Document")
    |> assign(:document, document)
    |> assign(:form, to_form(Documents.change_document(socket.assigns.current_scope, document)))
  end

  defp apply_action(socket, :new, _params) do
    document = %Document{user_id: socket.assigns.current_scope.user.id}

    socket
    |> assign(:page_title, "New Document")
    |> assign(:document, document)
    |> assign(:form, to_form(Documents.change_document(socket.assigns.current_scope, document)))
  end

  @impl true
  def handle_event("validate", %{"_target" => ["document"]}, socket) do
    {done, in_progress} = uploaded_entries(socket, :document)
    IO.inspect(done)
    IO.inspect(in_progress)
    {:noreply, socket}
  end

  def handle_event("save", %{}, socket) do
    entries =
      consume_uploaded_entries(socket, :document, fn %{path: path}, entry ->
        dest = Path.join([:code.priv_dir(:zaimu_tomo), "uploads", Path.basename(path)])
        File.cp!(path, dest)
        {:ok, Map.put(entry, :filepath, Path.join(["/", "uploads", Path.basename(dest)]))}
      end)

    document_params =
      case entries do
        [entry | _] -> %{"filepath" => entry.filepath, "filename" => entry.client_name}
        [] -> %{}
      end

    save_document(socket, socket.assigns.live_action, document_params)
  end

  defp save_document(socket, :edit, document_params) do
    case Documents.update_document(
           socket.assigns.current_scope,
           socket.assigns.document,
           document_params
         ) do
      {:ok, document} ->
        {:noreply,
         socket
         |> put_flash(:info, "Document updated successfully")
         |> push_navigate(
           to: return_path(socket.assigns.current_scope, socket.assigns.return_to, document)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_document(socket, :new, document_params) do
    case Documents.create_document(socket.assigns.current_scope, document_params) do
      {:ok, document} ->
        {:noreply,
         socket
         |> put_flash(:info, "Document created successfully")
         |> push_navigate(
           to: return_path(socket.assigns.current_scope, socket.assigns.return_to, document)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path(_scope, "index", _document), do: ~p"/documents"
  defp return_path(_scope, "show", document), do: ~p"/documents/#{document}"

  defp error_to_string(:too_large), do: "Too large"
  defp error_to_string(:too_many_files), do: "You have selected too many files"
  defp error_to_string(:not_accepted), do: "You have selected an unacceptable file type"

  defp to_megabytes_or_kilobytes(bytes) when is_integer(bytes) do
    case bytes do
      b when b < 1_048_576 ->
        kilobytes = (b / 1024) |> Float.round(1)

        if kilobytes < 1 do
          "#{kilobytes}MB"
        else
          "#{round(kilobytes)}KB"
        end

      _ ->
        megabytes = (bytes / 1_048_576) |> Float.round(1)
        "#{megabytes}MB"
    end
  end
end
