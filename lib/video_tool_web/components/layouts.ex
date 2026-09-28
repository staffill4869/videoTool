defmodule VideoToolWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use VideoToolWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  앱 껍데기. 모든 화면이 이걸 두르고 그린다.

  메뉴는 **만드는 곳 · 보는 곳 · 설정** 셋으로 묶는다. 예전엔 여덟 항목이 한 줄로 서 있어서
  어디가 무엇을 하는 곳인지 이름으로만 구분됐다.

  홈은 「현황」이다. `프로젝트` 표가 홈이던 시절엔 "지금 뭐가 돌고 있나" 를 볼 자리가
  아예 없었다. 「현황」 옆 배지는 **사람을 기다리는 수** 다 — 자동화가 아무리 돌아도
  풀리지 않는 것만 센다.

  ## Examples

      <Layouts.app flash={@flash} active={:overview}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  attr :active, :atom,
    default: nil,
    doc: "현재 메뉴 (:overview | :projects | :series | :dashboard | :agent | ...)"

  def app(assigns) do
    assigns = assign(assigns, :attention, attention())

    ~H"""
    <div class="flex min-h-screen">
      <aside class="hidden w-60 shrink-0 flex-col border-r border-base-300 bg-base-200 px-3 py-5 md:flex">
        <.link navigate={~p"/"} class="block px-2 pb-4">
          <div class="text-lg font-bold tracking-tight">videoTool</div>
          <div class="text-xs text-base-content/60">영상 제작 파이프라인</div>
        </.link>

        <.nav_item navigate={~p"/"} icon="hero-home" label="현황" active={@active == :overview}>
          <span
            :if={@attention > 0}
            class="rounded-md bg-warning px-1.5 py-0.5 font-mono text-[11px] font-semibold text-warning-content"
          >
            {@attention}
          </span>
        </.nav_item>

        <.nav_group label="만드는 곳" />
        <.nav_item
          navigate={~p"/projects"}
          icon="hero-film"
          label="프로젝트"
          active={@active == :projects}
        />
        <.nav_item
          navigate={~p"/series"}
          icon="hero-arrow-path-rounded-square"
          label="반복 제작"
          active={@active == :series}
        />

        <.nav_group label="보는 곳" />
        <.nav_item
          navigate={~p"/dashboard"}
          icon="hero-chart-bar"
          label="성과"
          active={@active == :dashboard}
        />
        <.nav_item
          navigate={~p"/agent"}
          icon="hero-cpu-chip"
          label="에이전트"
          active={@active == :agent}
        />

        <.nav_group label="설정" />
        <.nav_item
          navigate={~p"/prompts"}
          icon="hero-command-line"
          label="프롬프트"
          active={@active == :prompts}
          small
        />
        <.nav_item
          navigate={~p"/voices"}
          icon="hero-speaker-wave"
          label="목소리"
          active={@active == :voices}
          small
        />
        <.nav_item
          navigate={~p"/channels"}
          icon="hero-megaphone"
          label="발행 채널"
          active={@active == :channels}
          small
        />
        <.nav_item
          navigate={~p"/settings"}
          icon="hero-cog-6-tooth"
          label="환경 · 연결"
          active={@active == :settings}
          small
        />

        <div class="grow"></div>

        <div class="border-t border-base-300 pt-3">
          <.theme_toggle />
          <div class="mt-3 px-2 text-[11px] leading-relaxed text-base-content/50">
            조작은 MCP 로 한다.<br />이 화면은 결과를 눈으로 보는 곳이다.
          </div>
        </div>
      </aside>

      <div class="min-w-0 flex-1">
        <header class="flex items-center gap-3 border-b border-base-300 px-4 py-3 md:hidden">
          <.link navigate={~p"/"} class="font-bold">videoTool</.link>
          <span
            :if={@attention > 0}
            class="rounded-md bg-warning px-1.5 py-0.5 font-mono text-[11px] font-semibold text-warning-content"
          >
            {@attention}
          </span>
          <div class="grow"></div>
          <.theme_toggle />
        </header>

        <%!-- 폭을 제한하지 않는다. max-w 를 걸면 왼쪽 사이드바(240px)만큼 밀린 자리에서
              가운데 정렬돼, 넓은 화면일수록 **본문이 오른쪽으로 치우쳐** 보인다.
              프롬프트·대본처럼 긴 글을 읽는 화면이 많아서 폭은 넓을수록 낫다. --%>
        <main class="px-4 py-6 pb-24 sm:px-6 md:pb-6 lg:px-8">
          <div class="w-full space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <nav class="fixed inset-x-0 bottom-0 z-40 grid grid-cols-4 border-t border-base-300 bg-base-100 md:hidden">
      <.tab_item navigate={~p"/"} icon="hero-home" label="현황" active={@active == :overview} />
      <.tab_item
        navigate={~p"/projects"}
        icon="hero-film"
        label="프로젝트"
        active={@active == :projects}
      />
      <.tab_item
        navigate={~p"/dashboard"}
        icon="hero-chart-bar"
        label="성과"
        active={@active == :dashboard}
      />
      <.tab_item
        navigate={~p"/agent"}
        icon="hero-cpu-chip"
        label="에이전트"
        active={@active == :agent}
      />
    </nav>

    <.flash_group flash={@flash} />
    """
  end

  # 사람을 기다리는 수. 연결 안내 화면에서도 껍데기를 쓰므로 실패해도 화면은 떠야 한다.
  defp attention do
    VideoTool.Progress.attention_count()
  rescue
    _ -> 0
  end

  attr :label, :string, required: true

  defp nav_group(assigns) do
    ~H"""
    <div class="px-3 pb-1 pt-4 text-[10px] font-semibold tracking-wider text-base-content/40">
      {@label}
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :small, :boolean, default: false
  slot :inner_block

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2.5 rounded-lg px-2.5",
        (@small && "min-h-10 text-[13px]") || "min-h-11 text-sm",
        (@active && "bg-base-content font-semibold text-base-100") ||
          "text-base-content/80 hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0" />
      <span class="grow truncate">{@label}</span>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp tab_item(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex min-h-14 flex-col items-center justify-center gap-1",
        (@active && "font-semibold text-base-content") || "text-base-content/60"
      ]}
    >
      <.icon name={@icon} class="size-[18px]" />
      <span class="text-[11px]">{@label}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
