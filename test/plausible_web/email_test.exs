defmodule PlausibleWeb.EmailTest do
  alias PlausibleWeb.Email
  use ExUnit.Case, async: true
  import Plausible.Factory

  describe "base_email layout" do
    test "greets user by first name if user in template assigns" do
      email =
        Email.base_email()
        |> Email.render("welcome_email.html", %{
          user: build(:user, name: "John Doe"),
          code: "123"
        })

      assert email.html_body =~ "Hey John,"
    end

    test "greets impersonally when user not in template assigns" do
      email =
        Email.base_email()
        |> Email.render("welcome_email.html")

      assert email.html_body =~ "Hey,"
    end

    test "renders plausible link" do
      email =
        Email.base_email()
        |> Email.render("welcome_email.html")

      assert email.html_body =~ plausible_link()
    end

    test "renders unsubscribe placeholder" do
      email =
        Email.base_email()
        |> Email.render("welcome_email.html")

      assert email.html_body =~ "{{{ pm:unsubscribe }}}"
    end

    test "can be disabled with a nil layout" do
      email =
        Email.base_email(%{layout: nil})
        |> Email.render("welcome_email.html", %{
          user: build(:user, name: "John Doe")
        })

      refute email.html_body =~ "Hey John,"
      refute email.html_body =~ plausible_link()
    end
  end

  describe "priority email layout" do
    test "uses the `priority` message stream in Postmark" do
      email =
        Email.priority_email()
        |> Email.render("activation_email.html", %{
          user: build(:user, name: "John Doe"),
          code: "123"
        })

      assert %{"MessageStream" => "priority"} = email.private[:message_params]
    end

    test "greets user by first name if user in template assigns" do
      email =
        Email.priority_email()
        |> Email.render("activation_email.html", %{
          user: build(:user, name: "John Doe"),
          code: "123"
        })

      assert email.html_body =~ "Hey John,"
    end

    test "greets impersonally when user not in template assigns" do
      email =
        Email.priority_email()
        |> Email.render("password_reset_email.html", %{
          reset_link: "imaginary"
        })

      assert email.html_body =~ "Hey,"
    end

    test "renders plausible link" do
      email =
        Email.priority_email()
        |> Email.render("password_reset_email.html", %{
          reset_link: "imaginary"
        })

      assert email.html_body =~ plausible_link()
    end

    test "does not render unsubscribe placeholder" do
      email =
        Email.priority_email()
        |> Email.render("password_reset_email.html", %{
          reset_link: "imaginary"
        })

      refute email.html_body =~ "{{{ pm:unsubscribe }}}"
    end

    test "can be disabled with a nil layout" do
      email =
        Email.priority_email(%{layout: nil})
        |> Email.render("password_reset_email.html", %{
          reset_link: "imaginary"
        })

      refute email.html_body =~ "Hey John,"
      refute email.html_body =~ plausible_link()
    end
  end

  describe "over_limit_email/3" do
    test "renders usage, suggested plan, and links to upgrade and account settings" do
      user = build(:user)
      penultimate_cycle = Date.range(~D[2023-03-01], ~D[2023-03-31])
      last_cycle = Date.range(~D[2023-04-01], ~D[2023-04-30])
      suggested_plan = %Plausible.Billing.Plan{volume: "100k"}

      usage = %{
        penultimate_cycle: %{date_range: penultimate_cycle, total: 12_300},
        last_cycle: %{date_range: last_cycle, total: 32_100}
      }

      %{html_body: html_body, subject: subject} =
        PlausibleWeb.Email.over_limit_email(user, usage, suggested_plan)

      assert subject == "[Action required] You have outgrown your Plausible subscription tier"

      assert html_body =~ PlausibleWeb.TextHelpers.format_date_range(last_cycle)
      assert html_body =~ "We recommend you upgrade to the 100k/mo plan"
      assert html_body =~ "your account recorded 32,100 billable pageviews"

      assert html_body =~
               "cycle before that (#{PlausibleWeb.TextHelpers.format_date_range(penultimate_cycle)}), your account used 12,300 billable pageviews"

      assert html_body =~ "/billing/choose-plan\">Click here to upgrade your subscription</a>"
      assert html_body =~ "/settings\">account settings</a>"
    end

    test "asks enterprise level usage to contact us" do
      user = build(:user)
      penultimate_cycle = Date.range(~D[2023-03-01], ~D[2023-03-31])
      last_cycle = Date.range(~D[2023-04-01], ~D[2023-04-30])
      suggested_plan = :enterprise

      usage = %{
        penultimate_cycle: %{date_range: penultimate_cycle, total: 12_300},
        last_cycle: %{date_range: last_cycle, total: 32_100}
      }

      %{html_body: html_body} = PlausibleWeb.Email.over_limit_email(user, usage, suggested_plan)

      refute html_body =~ "Click here to upgrade your subscription"
      assert html_body =~ "Your usage exceeds our standard plans, so please reply back"
    end
  end

  describe "dashboard_locked/3" do
    test "renders usage, suggested plan, and links to upgrade and account settings" do
      user = build(:user)
      penultimate_cycle = Date.range(~D[2023-03-01], ~D[2023-03-31])
      last_cycle = Date.range(~D[2023-04-01], ~D[2023-04-30])
      suggested_plan = %Plausible.Billing.Plan{volume: "100k"}

      usage = %{
        penultimate_cycle: %{date_range: penultimate_cycle, total: 12_300},
        last_cycle: %{date_range: last_cycle, total: 32_100}
      }

      %{html_body: html_body, subject: subject} =
        PlausibleWeb.Email.dashboard_locked(user, usage, suggested_plan)

      assert subject == "[Action required] Your Plausible dashboard is now locked"

      assert html_body =~ PlausibleWeb.TextHelpers.format_date_range(last_cycle)
      assert html_body =~ "We recommend you upgrade to the 100k/mo plan"
      assert html_body =~ "your account recorded 32,100 billable pageviews"

      assert html_body =~
               "cycle before that (#{PlausibleWeb.TextHelpers.format_date_range(penultimate_cycle)}), the usage was 12,300 billable pageviews"

      assert html_body =~ "/billing/choose-plan\">Click here to upgrade your subscription</a>"
      assert html_body =~ "/settings\">account settings</a>"
    end

    test "asks enterprise level usage to contact us" do
      user = build(:user)
      penultimate_cycle = Date.range(~D[2023-03-01], ~D[2023-03-31])
      last_cycle = Date.range(~D[2023-04-01], ~D[2023-04-30])
      suggested_plan = :enterprise

      usage = %{
        penultimate_cycle: %{date_range: penultimate_cycle, total: 12_300},
        last_cycle: %{date_range: last_cycle, total: 32_100}
      }

      %{html_body: html_body} = PlausibleWeb.Email.dashboard_locked(user, usage, suggested_plan)

      refute html_body =~ "Click here to upgrade your subscription"
      assert html_body =~ "Your usage exceeds our standard plans, so please reply back"
    end
  end

  describe "enterprise_over_limit_internal_email/4" do
    test "renders pageview usage by billing cycles + sites usage/limit" do
      user = build(:user)
      penultimate_cycle = Date.range(~D[2023-03-01], ~D[2023-03-31])
      last_cycle = Date.range(~D[2023-04-01], ~D[2023-04-30])

      pageview_usage = %{
        penultimate_cycle: %{date_range: penultimate_cycle, total: 100_141_888},
        last_cycle: %{date_range: last_cycle, total: 100_222_999}
      }

      %{html_body: html_body, subject: subject} =
        PlausibleWeb.Email.enterprise_over_limit_internal_email(user, pageview_usage, 80, 50)

      assert subject == "#{user.email} has outgrown their enterprise plan"

      assert html_body =~
               "Last billing cycle: #{PlausibleWeb.TextHelpers.format_date_range(last_cycle)}"

      assert html_body =~ "Last cycle pageview usage: 100,222,999 billable pageviews"

      assert html_body =~
               "Penultimate billing cycle: #{PlausibleWeb.TextHelpers.format_date_range(penultimate_cycle)}"

      assert html_body =~ "Penultimate cycle pageview usage: 100,141,888 billable pageviews"
      assert html_body =~ "Site usage: 80 / 50 allowed sites"
    end
  end

  def plausible_link() do
    plausible_url = PlausibleWeb.EmailView.plausible_url()
    "<a href=\"#{plausible_url}\">#{plausible_url}</a>"
  end
end
