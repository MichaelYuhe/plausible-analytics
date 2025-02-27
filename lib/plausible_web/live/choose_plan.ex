defmodule PlausibleWeb.Live.ChoosePlan do
  @moduledoc """
  LiveView for upgrading to a plan, or changing an existing plan.
  """
  use Phoenix.LiveView
  use Phoenix.HTML

  import PlausibleWeb.Components.Billing

  require Plausible.Billing.Subscription.Status

  alias Plausible.Users
  alias Plausible.Billing.{Plans, Plan, Quota, Subscription}
  alias PlausibleWeb.Router.Helpers, as: Routes

  @contact_link "https://plausible.io/contact"
  @billing_faq_link "https://plausible.io/docs/billing"

  def mount(_params, %{"user_id" => user_id}, socket) do
    socket =
      socket
      |> assign_new(:user, fn ->
        Users.with_subscription(user_id)
      end)
      |> assign_new(:usage, fn %{user: user} ->
        Quota.usage(user, with_features: true)
      end)
      |> assign_new(:last_30_days_usage, fn %{user: user, usage: usage} ->
        case usage do
          %{last_30_days: usage_cycle} -> usage_cycle.total
          _ -> Quota.usage_cycle(user, :last_30_days).total
        end
      end)
      |> assign_new(:owned_plan, fn %{user: %{subscription: subscription}} ->
        Plans.get_regular_plan(subscription, only_non_expired: true)
      end)
      |> assign_new(:owned_tier, fn %{owned_plan: owned_plan} ->
        if owned_plan, do: Map.get(owned_plan, :kind), else: nil
      end)
      |> assign_new(:recommended_tier, fn %{owned_plan: owned_plan, user: user, usage: usage} ->
        if owned_plan || usage.sites == 0, do: nil, else: Plans.suggest_tier(user)
      end)
      |> assign_new(:current_interval, fn %{user: user} ->
        current_user_subscription_interval(user.subscription)
      end)
      |> assign_new(:available_plans, fn %{user: user} ->
        Plans.available_plans_for(user, with_prices: true)
      end)
      |> assign_new(:available_volumes, fn %{available_plans: available_plans} ->
        get_available_volumes(available_plans)
      end)
      |> assign_new(:selected_volume, fn %{
                                           owned_plan: owned_plan,
                                           last_30_days_usage: last_30_days_usage,
                                           available_volumes: available_volumes
                                         } ->
        default_selected_volume(owned_plan, last_30_days_usage, available_volumes)
      end)
      |> assign_new(:selected_interval, fn %{current_interval: current_interval} ->
        current_interval || :monthly
      end)
      |> assign_new(:selected_growth_plan, fn %{
                                                available_plans: available_plans,
                                                selected_volume: selected_volume
                                              } ->
        get_plan_by_volume(available_plans.growth, selected_volume)
      end)
      |> assign_new(:selected_business_plan, fn %{
                                                  available_plans: available_plans,
                                                  selected_volume: selected_volume
                                                } ->
        get_plan_by_volume(available_plans.business, selected_volume)
      end)

    {:ok, socket}
  end

  def render(assigns) do
    growth_plan_to_render =
      assigns.selected_growth_plan || List.last(assigns.available_plans.growth)

    business_plan_to_render =
      assigns.selected_business_plan || List.last(assigns.available_plans.business)

    growth_benefits = growth_benefits(growth_plan_to_render)

    business_benefits = business_benefits(business_plan_to_render, growth_benefits)

    assigns =
      assigns
      |> assign(:growth_plan_to_render, growth_plan_to_render)
      |> assign(:business_plan_to_render, business_plan_to_render)
      |> assign(:growth_benefits, growth_benefits)
      |> assign(:business_benefits, business_benefits)
      |> assign(:enterprise_benefits, enterprise_benefits(business_benefits))

    ~H"""
    <div class="bg-gray-100 dark:bg-gray-900 pt-1 pb-12 sm:pb-16 text-gray-900 dark:text-gray-100">
      <div class="mx-auto max-w-7xl px-6 lg:px-20">
        <.subscription_past_due_notice class="pb-6" subscription={@user.subscription} />
        <.subscription_paused_notice class="pb-6" subscription={@user.subscription} />
        <.upgrade_ineligible_notice :if={@usage.sites == 0} />
        <div class="mx-auto max-w-4xl text-center">
          <p class="text-4xl font-bold tracking-tight lg:text-5xl">
            <%= if @owned_plan,
              do: "Change subscription plan",
              else: "Upgrade your account" %>
          </p>
        </div>
        <div class="mt-12 flex flex-col gap-8 lg:flex-row items-center lg:items-baseline">
          <.interval_picker selected_interval={@selected_interval} />
          <.slider_output volume={@selected_volume} available_volumes={@available_volumes} />
          <.slider selected_volume={@selected_volume} available_volumes={@available_volumes} />
        </div>
        <div class="mt-6 isolate mx-auto grid max-w-md grid-cols-1 gap-8 lg:mx-0 lg:max-w-none lg:grid-cols-3">
          <.plan_box
            kind={:growth}
            owned={@owned_tier == :growth}
            recommended={@recommended_tier == :growth}
            plan_to_render={@growth_plan_to_render}
            benefits={@growth_benefits}
            available={!!@selected_growth_plan}
            {assigns}
          />
          <.plan_box
            kind={:business}
            owned={@owned_tier == :business}
            recommended={@recommended_tier == :business}
            plan_to_render={@business_plan_to_render}
            benefits={@business_benefits}
            available={!!@selected_business_plan}
            {assigns}
          />
          <.enterprise_plan_box benefits={@enterprise_benefits} />
        </div>
        <p class="mx-auto mt-8 max-w-2xl text-center text-lg leading-8 text-gray-600 dark:text-gray-400">
          You have used <b><%= PlausibleWeb.AuthView.delimit_integer(@last_30_days_usage) %></b>
          billable pageviews in the last 30 days
        </p>
        <.pageview_limit_notice :if={!@owned_plan} />
        <.help_links />
      </div>
    </div>
    <.slider_styles />
    <.paddle_script />
    """
  end

  def handle_event("set_interval", %{"interval" => interval}, socket) do
    new_interval =
      case interval do
        "yearly" -> :yearly
        "monthly" -> :monthly
      end

    {:noreply, assign(socket, selected_interval: new_interval)}
  end

  def handle_event("slide", %{"slider" => index}, socket) do
    index = String.to_integer(index)
    %{available_plans: available_plans, available_volumes: available_volumes} = socket.assigns

    new_volume =
      if index == length(available_volumes) do
        :enterprise
      else
        Enum.at(available_volumes, index)
      end

    {:noreply,
     assign(socket,
       selected_volume: new_volume,
       selected_growth_plan: get_plan_by_volume(available_plans.growth, new_volume),
       selected_business_plan: get_plan_by_volume(available_plans.business, new_volume)
     )}
  end

  defp default_selected_volume(%Plan{monthly_pageview_limit: limit}, _, _), do: limit

  defp default_selected_volume(_, last_30_days_usage, available_volumes) do
    Enum.find(available_volumes, &(last_30_days_usage < &1)) || :enterprise
  end

  defp current_user_subscription_interval(subscription) do
    case Plans.subscription_interval(subscription) do
      "yearly" -> :yearly
      "monthly" -> :monthly
      _ -> nil
    end
  end

  defp get_plan_by_volume(_, :enterprise), do: nil

  defp get_plan_by_volume(plans, volume) do
    Enum.find(plans, &(&1.monthly_pageview_limit == volume))
  end

  defp interval_picker(assigns) do
    ~H"""
    <div class="lg:flex-1 lg:order-3 lg:justify-end flex">
      <div class="relative">
        <.two_months_free />
        <fieldset class="grid grid-cols-2 gap-x-1 rounded-full bg-white dark:bg-gray-700 p-1 text-center text-sm font-semibold leading-5 shadow dark:ring-gray-600">
          <label
            class={"cursor-pointer rounded-full px-2.5 py-1 text-gray-900 dark:text-white #{if @selected_interval == :monthly, do: "bg-indigo-600 text-white"}"}
            phx-click="set_interval"
            phx-value-interval="monthly"
          >
            <input type="radio" name="frequency" value="monthly" class="sr-only" />
            <span>Monthly</span>
          </label>
          <label
            class={"cursor-pointer rounded-full px-2.5 py-1 text-gray-900 dark:text-white #{if @selected_interval == :yearly, do: "bg-indigo-600 text-white"}"}
            phx-click="set_interval"
            phx-value-interval="yearly"
          >
            <input type="radio" name="frequency" value="yearly" class="sr-only" />
            <span>Yearly</span>
          </label>
        </fieldset>
      </div>
    </div>
    """
  end

  def two_months_free(assigns) do
    ~H"""
    <span class="absolute -right-5 -top-4 whitespace-no-wrap w-max px-2.5 py-0.5 rounded-full text-xs font-medium leading-4 bg-yellow-100 border border-yellow-300 text-yellow-700">
      2 months free
    </span>
    """
  end

  defp slider(assigns) do
    slider_labels =
      Enum.map(
        assigns.available_volumes ++ [:enterprise],
        &format_volume(&1, assigns.available_volumes)
      )

    assigns = assign(assigns, :slider_labels, slider_labels)

    ~H"""
    <form class="max-w-md lg:max-w-none w-full lg:w-1/2 lg:order-2">
      <div class="flex items-baseline space-x-2">
        <span class="text-xs font-medium text-gray-600 dark:text-gray-200">
          <%= List.first(@slider_labels) %>
        </span>
        <div class="flex-1 relative">
          <input
            phx-change="slide"
            id="slider"
            name="slider"
            class="shadow mt-8 dark:bg-gray-600 dark:border-none"
            type="range"
            min="0"
            max={length(@available_volumes)}
            step="1"
            value={
              Enum.find_index(@available_volumes, &(&1 == @selected_volume)) ||
                length(@available_volumes)
            }
            oninput="repositionBubble()"
          />
          <output
            id="slider-bubble"
            class="absolute bottom-[35px] py-[4px] px-[12px] -translate-x-1/2 rounded-md text-white bg-indigo-600 position text-xs font-medium"
            phx-update="ignore"
          />
        </div>
        <span class="text-xs font-medium text-gray-600 dark:text-gray-200">
          <%= List.last(@slider_labels) %>
        </span>
      </div>
    </form>

    <script>
      const SLIDER_LABELS = <%= raw Jason.encode!(@slider_labels) %>

      function repositionBubble() {
        const input = document.getElementById("slider")
        const percentage = Number((input.value / input.max) * 100)
        const bubble = document.getElementById("slider-bubble")

        bubble.innerHTML = SLIDER_LABELS[input.value]
        bubble.style.left = `calc(${percentage}% + (${13.87 - percentage * 0.26}px))`
      }

      repositionBubble()
    </script>
    """
  end

  defp plan_box(assigns) do
    highlight =
      cond do
        assigns.owned -> "Current"
        assigns.recommended -> "Recommended"
        true -> nil
      end

    assigns = assign(assigns, :highlight, highlight)

    ~H"""
    <div
      id={"#{@kind}-plan-box"}
      class={[
        "shadow-lg bg-white rounded-3xl px-6 sm:px-8 py-4 sm:py-6 dark:bg-gray-800",
        !@highlight && "dark:ring-gray-600",
        @highlight && "ring-2 ring-indigo-600 dark:ring-indigo-300"
      ]}
    >
      <div class="flex items-center justify-between gap-x-4">
        <h3 class={[
          "text-lg font-semibold leading-8",
          !@highlight && "text-gray-900 dark:text-gray-100",
          @highlight && "text-indigo-600 dark:text-indigo-300"
        ]}>
          <%= String.capitalize(to_string(@kind)) %>
        </h3>
        <.pill :if={@highlight} text={@highlight} />
      </div>
      <div>
        <.render_price_info available={@available} {assigns} />
        <%= if @available do %>
          <.checkout id={"#{@kind}-checkout"} {assigns} />
        <% else %>
          <.contact_button class="bg-indigo-600 hover:bg-indigo-500 text-white" />
        <% end %>
      </div>
      <%= if @owned && @kind == :growth && @plan_to_render.generation < 4 do %>
        <.growth_grandfathering_notice />
      <% else %>
        <ul
          role="list"
          class="mt-8 space-y-3 text-sm leading-6 text-gray-600 dark:text-gray-100 xl:mt-10"
        >
          <.plan_benefit :for={benefit <- @benefits}><%= benefit %></.plan_benefit>
        </ul>
      <% end %>
    </div>
    """
  end

  defp checkout(assigns) do
    paddle_product_id = get_paddle_product_id(assigns.plan_to_render, assigns.selected_interval)
    change_plan_link_text = change_plan_link_text(assigns)

    usage_within_limits =
      Quota.ensure_can_subscribe_to_plan(assigns.user, assigns.plan_to_render, assigns.usage) ==
        :ok

    subscription = assigns.user.subscription

    billing_details_expired =
      Subscription.Status.in?(subscription, [
        Subscription.Status.paused(),
        Subscription.Status.past_due()
      ])

    subscription_deleted = Subscription.Status.deleted?(subscription)

    {checkout_disabled, disabled_message} =
      cond do
        assigns.usage.sites == 0 ->
          {true, nil}

        change_plan_link_text == "Currently on this plan" && not subscription_deleted ->
          {true, nil}

        assigns.available && !usage_within_limits ->
          {true, "Your usage exceeds this plan"}

        billing_details_expired ->
          {true, "Please update your billing details first"}

        true ->
          {false, nil}
      end

    features_to_lose = assigns.usage.features -- assigns.plan_to_render.features

    assigns =
      assigns
      |> assign(:paddle_product_id, paddle_product_id)
      |> assign(:change_plan_link_text, change_plan_link_text)
      |> assign(:checkout_disabled, checkout_disabled)
      |> assign(:disabled_message, disabled_message)
      |> assign(:confirm_message, losing_features_message(features_to_lose))

    ~H"""
    <%= if @owned_plan && Plausible.Billing.Subscriptions.resumable?(@user.subscription) do %>
      <.change_plan_link {assigns} />
    <% else %>
      <.paddle_button {assigns}>Upgrade</.paddle_button>
    <% end %>
    <p :if={@disabled_message} class="h-0 text-center text-sm text-red-700 dark:text-red-500">
      <%= @disabled_message %>
    </p>
    """
  end

  defp losing_features_message([]), do: nil

  defp losing_features_message(features_to_lose) do
    features_list_str =
      features_to_lose
      |> Enum.map(& &1.display_name)
      |> PlausibleWeb.TextHelpers.pretty_join()

    "This plan does not support #{features_list_str}, which you are currently using. Please note that by subscribing to this plan you will lose access to #{if length(features_to_lose) == 1, do: "this feature", else: "these features"}."
  end

  defp growth_grandfathering_notice(assigns) do
    ~H"""
    <ul class="mt-8 space-y-3 text-sm leading-6 text-gray-600 text-justify dark:text-gray-100 xl:mt-10">
      Your subscription has been grandfathered in at the same rate and terms as when you first joined. If you don't need the "Business" features, you're welcome to stay on this plan. You can adjust the pageview limit or change the billing frequency of this grandfathered plan. If you're interested in business features, you can upgrade to the new "Business" plan.
    </ul>
    """
  end

  def render_price_info(%{available: false} = assigns) do
    ~H"""
    <p id={"#{@kind}-custom-price"} class="mt-6 flex items-baseline gap-x-1">
      <span class="text-4xl font-bold tracking-tight text-gray-900 dark:text-white">
        Custom
      </span>
    </p>
    <p class="h-4 mt-1"></p>
    """
  end

  def render_price_info(assigns) do
    ~H"""
    <p class="mt-6 flex items-baseline gap-x-1">
      <.price_tag
        kind={@kind}
        selected_interval={@selected_interval}
        plan_to_render={@plan_to_render}
      />
    </p>
    <p class="mt-1 text-xs">+ VAT if applicable</p>
    """
  end

  defp change_plan_link(assigns) do
    confirmed =
      if assigns.confirm_message, do: "confirm(\"#{assigns.confirm_message}\")", else: "true"

    assigns = assign(assigns, :confirmed, confirmed)

    ~H"""
    <button
      id={"#{@kind}-checkout"}
      onclick={"if (#{@confirmed}) {window.location = '#{Routes.billing_path(PlausibleWeb.Endpoint, :change_plan_preview, @paddle_product_id)}'}"}
      class={[
        "w-full mt-6 block rounded-md py-2 px-3 text-center text-sm font-semibold leading-6 text-white",
        !@checkout_disabled && "bg-indigo-600 hover:bg-indigo-500",
        @checkout_disabled && "pointer-events-none bg-gray-400 dark:bg-gray-600"
      ]}
    >
      <%= @change_plan_link_text %>
    </button>
    """
  end

  slot :inner_block, required: true
  attr :icon_color, :string, default: "indigo-600"

  defp plan_benefit(assigns) do
    ~H"""
    <li class="flex gap-x-3">
      <.check_icon class={"text-#{@icon_color} dark:text-green-600"} />
      <%= render_slot(@inner_block) %>
    </li>
    """
  end

  defp contact_button(assigns) do
    ~H"""
    <.link
      href={contact_link()}
      class={[
        "mt-6 block rounded-md py-2 px-3 text-center text-sm font-semibold leading-6 bg-gray-800 hover:bg-gray-700 text-white dark:bg-indigo-600 dark:hover:bg-indigo-500",
        @class
      ]}
    >
      Contact us
    </.link>
    """
  end

  defp enterprise_plan_box(assigns) do
    ~H"""
    <div
      id="enterprise-plan-box"
      class="rounded-3xl px-6 sm:px-8 py-4 sm:py-6 bg-gray-900 shadow-xl dark:bg-gray-800 dark:ring-gray-600"
    >
      <h3 class="text-lg font-semibold leading-8 text-white dark:text-gray-100">Enterprise</h3>
      <p class="mt-6 flex items-baseline gap-x-1">
        <span class="text-4xl font-bold tracking-tight text-white dark:text-gray-100">
          Custom
        </span>
      </p>
      <p class="h-4 mt-1"></p>
      <.contact_button class="" />
      <ul
        role="list"
        class="mt-8 space-y-3 text-sm leading-6 xl:mt-10 text-gray-300 dark:text-gray-100"
      >
        <.plan_benefit :for={benefit <- @benefits}>
          <%= if is_binary(benefit), do: benefit, else: benefit.(assigns) %>
        </.plan_benefit>
      </ul>
    </div>
    """
  end

  defp pill(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-x-4">
      <p
        id="highlight-pill"
        class="rounded-full bg-indigo-600/10 px-2.5 py-1 text-xs font-semibold leading-5 text-indigo-600 dark:text-indigo-300 dark:ring-1 dark:ring-indigo-300/50"
      >
        <%= @text %>
      </p>
    </div>
    """
  end

  defp check_icon(assigns) do
    ~H"""
    <svg {%{class: "h-6 w-5 flex-none #{@class}", viewBox: "0 0 20 20",fill: "currentColor","aria-hidden": "true"}}>
      <path
        fill-rule="evenodd"
        d="M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  defp pageview_limit_notice(assigns) do
    ~H"""
    <div class="mt-12 mx-auto mt-6 max-w-2xl">
      <dt>
        <p class="w-full text-center text-gray-900 dark:text-gray-100">
          <span class="text-center font-semibold leading-7">
            What happens if I go over my page views limit?
          </span>
        </p>
      </dt>
      <dd class="mt-3">
        <div class="text-justify leading-7 block text-gray-600 dark:text-gray-100">
          You will never be charged extra for an occasional traffic spike. There are no surprise fees and your card will never be charged unexpectedly.               If your page views exceed your plan for two consecutive months, we will contact you to upgrade to a higher plan for the following month. You will have two weeks to make a decision. You can decide to continue with a higher plan or to cancel your account at that point.
        </div>
      </dd>
    </div>
    """
  end

  defp help_links(assigns) do
    ~H"""
    <div class="mt-8 text-center">
      Questions? <a class="text-indigo-600" href={contact_link()}>Contact us</a>
      or see <a class="text-indigo-600" href={billing_faq_link()}>billing FAQ</a>
    </div>
    """
  end

  defp price_tag(%{plan_to_render: %Plan{monthly_cost: nil}} = assigns) do
    ~H"""
    <span class="text-4xl font-bold tracking-tight text-gray-900 dark:text-gray-100">
      N/A
    </span>
    """
  end

  defp price_tag(%{selected_interval: :monthly} = assigns) do
    ~H"""
    <span
      id={"#{@kind}-price-tag-amount"}
      class="text-4xl font-bold tracking-tight text-gray-900 dark:text-gray-100"
    >
      <%= @plan_to_render.monthly_cost |> format_price() %>
    </span>
    <span
      id={"#{@kind}-price-tag-interval"}
      class="text-sm font-semibold leading-6 text-gray-600 dark:text-gray-500"
    >
      /month
    </span>
    """
  end

  defp price_tag(%{selected_interval: :yearly} = assigns) do
    ~H"""
    <span class="text-2xl font-bold w-max tracking-tight line-through text-gray-500 dark:text-gray-600 mr-1">
      <%= @plan_to_render.monthly_cost |> Money.mult!(12) |> format_price() %>
    </span>
    <span
      id={"#{@kind}-price-tag-amount"}
      class="text-4xl font-bold tracking-tight text-gray-900 dark:text-gray-100"
    >
      <%= @plan_to_render.yearly_cost |> format_price() %>
    </span>
    <span id={"#{@kind}-price-tag-interval"} class="text-sm font-semibold leading-6 text-gray-600">
      /year
    </span>
    """
  end

  defp slider_styles(assigns) do
    ~H"""
    <style>
      input[type="range"] {
        -moz-appearance: none;
        -webkit-appearance: none;
        background: white;
        border-radius: 3px;
        height: 6px;
        width: 100%;
        margin-bottom: 9px;
        outline: none;
      }

      input[type="range"]::-webkit-slider-thumb {
        appearance: none;
        -webkit-appearance: none;
        background-color: #5f48ff;
        background-image: url("data:image/svg+xml;charset=US-ASCII,%3Csvg%20width%3D%2212%22%20height%3D%228%22%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%3E%3Cpath%20d%3D%22M8%20.5v7L12%204zM0%204l4%203.5v-7z%22%20fill%3D%22%23FFFFFF%22%20fill-rule%3D%22nonzero%22%2F%3E%3C%2Fsvg%3E");
        background-position: center;
        background-repeat: no-repeat;
        border: 0;
        border-radius: 50%;
        cursor: pointer;
        height: 26px;
        width: 26px;
      }

      input[type="range"]::-moz-range-thumb {
        background-color: #5f48ff;
        background-image: url("data:image/svg+xml;charset=US-ASCII,%3Csvg%20width%3D%2212%22%20height%3D%228%22%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%3E%3Cpath%20d%3D%22M8%20.5v7L12%204zM0%204l4%203.5v-7z%22%20fill%3D%22%23FFFFFF%22%20fill-rule%3D%22nonzero%22%2F%3E%3C%2Fsvg%3E");
        background-position: center;
        background-repeat: no-repeat;
        border: 0;
        border: none;
        border-radius: 50%;
        cursor: pointer;
        height: 26px;
        width: 26px;
      }

      input[type="range"]::-ms-thumb {
        background-color: #5f48ff;
        background-image: url("data:image/svg+xml;charset=US-ASCII,%3Csvg%20width%3D%2212%22%20height%3D%228%22%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%3E%3Cpath%20d%3D%22M8%20.5v7L12%204zM0%204l4%203.5v-7z%22%20fill%3D%22%23FFFFFF%22%20fill-rule%3D%22nonzero%22%2F%3E%3C%2Fsvg%3E");
        background-position: center;
        background-repeat: no-repeat;
        border: 0;
        border-radius: 50%;
        cursor: pointer;
        height: 26px;
        width: 26px;
      }

      input[type="range"]::-moz-focus-outer {
        border: 0;
      }
    </style>
    """
  end

  defp change_plan_link_text(
         %{
           owned_plan: %Plan{kind: from_kind, monthly_pageview_limit: from_volume},
           plan_to_render: %Plan{kind: to_kind, monthly_pageview_limit: to_volume},
           current_interval: from_interval,
           selected_interval: to_interval
         } = _assigns
       ) do
    cond do
      from_kind == :business && to_kind == :growth ->
        "Downgrade to Growth"

      from_kind == :growth && to_kind == :business ->
        "Upgrade to Business"

      from_volume == to_volume && from_interval == to_interval ->
        "Currently on this plan"

      from_volume == to_volume ->
        "Change billing interval"

      from_volume > to_volume ->
        "Downgrade"

      true ->
        "Upgrade"
    end
  end

  defp change_plan_link_text(_), do: nil

  defp get_available_volumes(%{business: business_plans, growth: growth_plans}) do
    growth_volumes = Enum.map(growth_plans, & &1.monthly_pageview_limit)
    business_volumes = Enum.map(business_plans, & &1.monthly_pageview_limit)

    (growth_volumes ++ business_volumes)
    |> Enum.uniq()
  end

  defp get_paddle_product_id(%Plan{monthly_product_id: plan_id}, :monthly), do: plan_id
  defp get_paddle_product_id(%Plan{yearly_product_id: plan_id}, :yearly), do: plan_id

  attr :volume, :any
  attr :available_volumes, :list

  defp slider_output(assigns) do
    ~H"""
    <output class="lg:w-1/4 lg:order-1 font-medium text-lg text-gray-600 dark:text-gray-200">
      <span :if={@volume != :enterprise}>Up to</span>
      <strong id="slider-value" class="text-gray-900 dark:text-gray-100">
        <%= format_volume(@volume, @available_volumes) %>
      </strong>
      monthly pageviews
    </output>
    """
  end

  defp format_volume(volume, available_volumes) do
    if volume == :enterprise do
      available_volumes
      |> List.last()
      |> PlausibleWeb.StatsView.large_number_format()
      |> Kernel.<>("+")
    else
      PlausibleWeb.StatsView.large_number_format(volume)
    end
  end

  defp growth_benefits(plan) do
    [
      team_member_limit_benefit(plan),
      site_limit_benefit(plan),
      data_retention_benefit(plan),
      "Intuitive, fast and privacy-friendly dashboard",
      "Email/Slack reports",
      "Google Analytics import"
    ]
    |> Kernel.++(feature_benefits(plan))
    |> Enum.filter(& &1)
  end

  defp business_benefits(plan, growth_benefits) do
    [
      "Everything in Growth",
      team_member_limit_benefit(plan),
      site_limit_benefit(plan),
      data_retention_benefit(plan)
    ]
    |> Kernel.++(feature_benefits(plan))
    |> Kernel.--(growth_benefits)
    |> Kernel.++(["Priority support"])
    |> Enum.filter(& &1)
  end

  defp enterprise_benefits(business_benefits) do
    team_members =
      if "Up to 10 team members" in business_benefits, do: "10+ team members"

    data_retention =
      if "5 years of data retention" in business_benefits, do: "5+ years of data retention"

    [
      "Everything in Business",
      team_members,
      "50+ sites",
      "600+ Stats API requests per hour",
      &sites_api_benefit/1,
      data_retention,
      "Technical onboarding"
    ]
    |> Enum.filter(& &1)
  end

  defp data_retention_benefit(%Plan{} = plan) do
    if plan.data_retention_in_years, do: "#{plan.data_retention_in_years} years of data retention"
  end

  defp team_member_limit_benefit(%Plan{} = plan) do
    case plan.team_member_limit do
      :unlimited -> "Unlimited team members"
      number -> "Up to #{number} team members"
    end
  end

  defp site_limit_benefit(%Plan{} = plan), do: "Up to #{plan.site_limit} sites"

  defp feature_benefits(%Plan{} = plan) do
    Enum.map(plan.features, fn feature_mod ->
      case feature_mod.name() do
        :goals -> "Goals and custom events"
        :stats_api -> "Stats API (600 requests per hour)"
        :revenue_goals -> "Ecommerce revenue attribution"
        _ -> feature_mod.display_name()
      end
    end)
  end

  defp sites_api_benefit(assigns) do
    ~H"""
    <p>
      Sites API access for
      <.link
        class="text-indigo-500 hover:text-indigo-400"
        href="https://plausible.io/white-label-web-analytics"
      >
        reselling
      </.link>
    </p>
    """
  end

  defp contact_link(), do: @contact_link

  defp billing_faq_link(), do: @billing_faq_link
end
