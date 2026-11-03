defmodule ZaimuTomoWeb.UserLive.Settings do
  use ZaimuTomoWeb, :live_view

  alias ZaimuTomo.Accounts
  alias ZaimuTomo.Accounts.Scope

  # Settings always opens; email and password changes, as sensitive actions,
  # stay locked until a recent login (sudo mode).
  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={:product}>
      <div class="settings-page">
        <header class="settings-header">
          <div>
            <p class="settings-eyebrow">Account settings / A personal touch</p>
            <h1>Your books. <em>Your rules.</em></h1>
            <p class="settings-intro">The details that make this space yours.</p>
          </div>
          <div class="settings-identity">
            <span class="settings-identity-label">Personal workspace</span>
            <div>
              <strong>{@current_scope.user.display_name || "Your account"}</strong>
              <span>{@current_email}</span>
            </div>
            <div class="settings-base-currency">
              <span>Base currency</span><strong>{@current_scope.user.base_currency}</strong>
            </div>
          </div>
        </header>

        <div class="settings-sections">
          <section class="settings-section" aria-labelledby="profile-settings-title">
            <div class="settings-section-heading">
              <span class="settings-section-number" aria-hidden="true">01</span>
              <div>
                <h2 id="profile-settings-title">Profile</h2>
                <p>Make it <em>personal.</em></p>
                <span class="settings-section-description">Your name. Your everyday currency.</span>
              </div>
            </div>
            <.form
              for={@profile_form}
              id="profile_form"
              class="settings-form"
              phx-submit="update_profile"
              phx-change="validate_profile"
            >
              <div class="settings-fields">
                <.input
                  field={@profile_form[:display_name]}
                  type="text"
                  class="settings-input"
                  label="Display name"
                  placeholder="How you'd like to be addressed"
                  autocomplete="name"
                />
                <.input
                  field={@profile_form[:base_currency]}
                  type="text"
                  class="settings-input settings-currency"
                  label="Base currency"
                  placeholder="EUR"
                  maxlength="3"
                  aria-describedby="currency-help"
                  required
                />
              </div>
              <p class="settings-help" id="currency-help">
                Use a three-letter currency code, such as CHF, EUR or USD.
              </p>
              <div class="settings-actions">
                <.button class="btn settings-save" phx-disable-with="Saving...">
                  Save Profile <.icon name="hero-arrow-right" class="size-4" />
                </.button>
              </div>
            </.form>
          </section>

          <section class="settings-section" aria-labelledby="email-settings-title">
            <div class="settings-section-heading">
              <span class="settings-section-number" aria-hidden="true">02</span>
              <div>
                <h2 id="email-settings-title">Email</h2>
                <p>Stay <em>connected.</em></p>
                <span class="settings-section-description">Your address for signing in and notifications.</span>
              </div>
            </div>
            <.form
              for={@email_form}
              id="email_form"
              class="settings-form"
              phx-submit="update_email"
              phx-change="validate_email"
            >
              <.input
                field={@email_form[:email]}
                type="email"
                class="settings-input"
                label="Email"
                autocomplete="username"
                readonly={!@sudo_mode?}
                aria-describedby="email-help"
                required
              />
              <p class="settings-help" id="email-help">
                We'll send a confirmation link to your new email address.
              </p>
              <div class="settings-actions">
                <.button
                  :if={@sudo_mode?}
                  id="email-submit"
                  class="btn settings-save"
                  phx-disable-with="Changing..."
                >
                  Change Email <.icon name="hero-arrow-right" class="size-4" />
                </.button>
                <.button
                  :if={!@sudo_mode?}
                  id="email-reauth"
                  class="btn settings-save"
                  href={~p"/users/log-in"}
                >
                  <.icon name="hero-lock-closed" class="size-4" /> Log in again to change
                </.button>
              </div>
            </.form>
          </section>

          <section class="settings-section" aria-labelledby="password-settings-title">
            <div class="settings-section-heading">
              <span class="settings-section-number" aria-hidden="true">03</span>
              <div>
                <h2 id="password-settings-title">Password</h2>
                <p>Keep it <em>private.</em></p>
                <span class="settings-section-description">Protect access to your financial workspace.</span>
              </div>
            </div>
            <div :if={!@sudo_mode?} id="password-locked" class="settings-locked">
              <.icon name="hero-shield-check" class="size-6" />
              <h3>Confirm your identity</h3>
              <p>For your safety, changing your email or password needs a fresh login.</p>
              <.button
                id="password-reauth"
                class="btn settings-save"
                href={~p"/users/log-in"}
              >
                <.icon name="hero-finger-print" class="size-4" /> Confirm it's you
              </.button>
            </div>
            <.form
              :if={@sudo_mode?}
              for={@password_form}
              id="password_form"
              class="settings-form"
              action={~p"/users/update-password"}
              method="post"
              phx-change="validate_password"
              phx-submit="update_password"
              phx-trigger-action={@trigger_submit}
            >
              <input
                name={@password_form[:email].name}
                type="hidden"
                id="hidden_user_email"
                autocomplete="username"
                value={@current_email}
              />
              <div class="settings-fields">
                <.input
                  field={@password_form[:password]}
                  type="password"
                  class="settings-input"
                  label="New password"
                  autocomplete="new-password"
                  aria-describedby="password-help"
                  required
                />
                <.input
                  field={@password_form[:password_confirmation]}
                  type="password"
                  class="settings-input"
                  label="Confirm new password"
                  autocomplete="new-password"
                />
              </div>
              <p class="settings-help" id="password-help">Choose at least 12 characters.</p>
              <div class="settings-actions">
                <.button class="btn settings-save" phx-disable-with="Saving...">
                  Save Password <.icon name="hero-arrow-right" class="size-4" />
                </.button>
              </div>
            </.form>
          </section>
        </div>
        <p class="settings-footnote">
          <.icon name="hero-lock-closed" class="size-3.5" />
          Your details stay yours. Changes are saved one section at a time.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)
    profile_changeset = Accounts.change_user_profile(user)

    socket =
      socket
      |> assign(:page_title, "Account settings")
      |> assign(:current_path, "/users/settings")
      |> assign(:current_email, user.email)
      |> assign(:sudo_mode?, Accounts.sudo_mode?(user))
      |> assign(:profile_form, to_form(profile_changeset))
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_profile", params, socket) do
    %{"user" => user_params} = params

    profile_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_profile(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, profile_form: profile_form)}
  end

  def handle_event("update_profile", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    case Accounts.update_user_profile(user, user_params) do
      {:ok, user} ->
        socket =
          socket
          |> assign(:current_scope, Scope.for_user(user))
          |> assign(:profile_form, to_form(Accounts.change_user_profile(user)))
          |> put_flash(:info, "Profile updated successfully.")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    with :ok <- check_sudo_mode(user),
         %{valid?: true} = changeset <- Accounts.change_user_email(user, user_params) do
      Accounts.deliver_user_update_email_instructions(
        Ecto.Changeset.apply_action!(changeset, :insert),
        user.email,
        &url(~p"/users/settings/confirm-email/#{&1}")
      )

      info = "A link to confirm your email change has been sent to the new address."
      {:noreply, socket |> put_flash(:info, info)}
    else
      :reauthenticate -> {:noreply, reauthenticate(socket)}
      changeset -> {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user

    with :ok <- check_sudo_mode(user),
         %{valid?: true} = changeset <- Accounts.change_user_password(user, user_params) do
      {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}
    else
      :reauthenticate -> {:noreply, reauthenticate(socket)}
      changeset -> {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  # The page can stay open past the sudo window, so check again on every sensitive submit.
  defp check_sudo_mode(user) do
    if Accounts.sudo_mode?(user), do: :ok, else: :reauthenticate
  end

  # The log-in page sends an already signed-in user back to settings.
  defp reauthenticate(socket) do
    socket
    |> put_flash(:error, "Log in again to change your email or password.")
    |> redirect(to: ~p"/users/log-in")
  end
end
