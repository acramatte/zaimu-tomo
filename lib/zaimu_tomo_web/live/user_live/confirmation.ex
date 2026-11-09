defmodule ZaimuTomoWeb.UserLive.Confirmation do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={:bare}>
      <main class="login-shell">
        <.auth_stage />

        <section class="auth-desk">
          <div class="slip-wrap">
            <div class="slip">
              <header class="slip-head">
                <p class="slip-kicker">Zaimutomo · Magic link</p>
                <h1 class="slip-title">
                  <%= cond do %>
                    <% !@user.confirmed_at -> %>
                      Confirm your account
                    <% @current_scope -> %>
                      Confirm it's you
                    <% true -> %>
                      Welcome back
                  <% end %>
                </h1>
                <p class="slip-meta">
                  <span>{Calendar.strftime(Date.utc_today(), "%d.%m.%Y")}</span>
                </p>
              </header>

              <div class="slip-methods">
                <span class="slip-label">Account</span>
                <span class="slip-account">{@user.email}</span>
              </div>

              <.form
                :if={!@user.confirmed_at}
                for={@form}
                id="confirmation_form"
                phx-submit="submit"
                action={~p"/users/log-in?_action=confirmed"}
                phx-trigger-action={@trigger_submit}
              >
                <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
                <.input field={@form[:remember_me]} type="checkbox" label="Keep me signed in" />
                <button
                  class="slip-submit"
                  phx-disable-with="Confirming…"
                  phx-mounted={JS.focus()}
                >
                  <span>Confirm and sign in</span>
                  <.icon name="hero-arrow-right" class="size-5 slip-arrow" />
                </button>
              </.form>

              <.form
                :if={@user.confirmed_at}
                for={@form}
                id="login_form"
                phx-submit="submit"
                action={~p"/users/log-in"}
                phx-trigger-action={@trigger_submit}
              >
                <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
                <.input
                  :if={!@current_scope}
                  field={@form[:remember_me]}
                  type="checkbox"
                  label="Keep me signed in"
                />
                <button class="slip-submit" phx-disable-with="Logging in…" phx-mounted={JS.focus()}>
                  <span>Log in</span>
                  <.icon name="hero-arrow-right" class="size-5 slip-arrow" />
                </button>
              </.form>

              <p :if={!@user.confirmed_at} class="slip-tip">
                Tip: If you prefer passwords, you can enable them in the user settings.
              </p>

              <div class="slip-stamp" aria-hidden="true">
                <span>Verified</span>
                <span class="kanji">友</span>
              </div>
            </div>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
