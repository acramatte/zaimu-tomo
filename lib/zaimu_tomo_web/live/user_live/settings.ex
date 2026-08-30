defmodule ZaimuTomoWeb.UserLive.Settings do
  use ZaimuTomoWeb, :live_view

  on_mount {ZaimuTomoWeb.UserAuth, :require_sudo_mode}

  alias ZaimuTomo.Accounts
  alias ZaimuTomo.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <h1 class="view-title">Account settings</h1>
    <p class="view-sub">Manage your profile, email address and password settings</p>

    <div class="grid gap-[18px]">
      <!-- Profile -->
      <section class="card" aria-labelledby="profile-settings-title">
        <div class="card-head">
          <div>
            <h2 id="profile-settings-title" class="card-title">Profile</h2>
            <div class="card-meta">How you appear in Zaimutomo and your primary currency</div>
          </div>
        </div>

        <.form
          for={@profile_form}
          id="profile_form"
          phx-submit="update_profile"
          phx-change="validate_profile"
        >
          <.input
            field={@profile_form[:display_name]}
            type="text"
            label="Display name"
            placeholder="How you'd like to be addressed"
            autocomplete="name"
          />

          <.input
            field={@profile_form[:base_currency]}
            type="text"
            label="Base currency"
            placeholder="EUR"
            maxlength="3"
            required
          />

          <div class="mt-4">
            <.button variant="primary" phx-disable-with="Saving...">Save Profile</.button>
          </div>
        </.form>
      </section>

    <!-- Email -->
      <section class="card" aria-labelledby="email-settings-title">
        <div class="card-head">
          <div>
            <h2 id="email-settings-title" class="card-title">Email</h2>
            <div class="card-meta">Used to sign in and receive notifications</div>
          </div>
        </div>

        <.form
          for={@email_form}
          id="email_form"
          phx-submit="update_email"
          phx-change="validate_email"
        >
          <.input
            field={@email_form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            required
          />

          <div class="mt-4">
            <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
          </div>
        </.form>
      </section>

    <!-- Password -->
      <section class="card" aria-labelledby="password-settings-title">
        <div class="card-head">
          <div>
            <h2 id="password-settings-title" class="card-title">Password</h2>
            <div class="card-meta">Set or update the password used for this account</div>
          </div>
        </div>

        <.form
          for={@password_form}
          id="password_form"
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

          <.input
            field={@password_form[:password]}
            type="password"
            label="New password"
            autocomplete="new-password"
            required
          />

          <.input
            field={@password_form[:password_confirmation]}
            type="password"
            label="Confirm new password"
            autocomplete="new-password"
          />

          <div class="mt-4">
            <.button variant="primary" phx-disable-with="Saving...">Save Password</.button>
          </div>
        </.form>
      </section>
    </div>
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
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
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
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
