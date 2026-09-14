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
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  attr :active, :atom, default: nil, doc: "현재 메뉴 (:projects | :series | :prompts | :channels)"

  def app(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <aside class="hidden w-56 shrink-0 border-r border-base-300 bg-base-200 md:block">
        <div class="px-4 py-5">
          <a href="/" class="block">
            <div class="text-lg font-bold tracking-tight">videoTool</div>
            <div class="text-xs text-base-content/60">AI 영상 제작</div>
          </a>
        </div>

        <nav class="px-2">
          <ul class="menu w-full gap-1">
            <li>
              <.link navigate={~p"/"} class={@active == :projects && "active font-semibold"}>
                프로젝트
              </.link>
            </li>
            <li>
              <.link navigate={~p"/dashboard"} class={@active == :dashboard && "active font-semibold"}>
                성과
              </.link>
            </li>
            <li>
              <.link navigate={~p"/series"} class={@active == :series && "active font-semibold"}>
                반복 제작
              </.link>
            </li>
            <li>
              <.link navigate={~p"/prompts"} class={@active == :prompts && "active font-semibold"}>
                프롬프트
              </.link>
            </li>
            <li>
              <.link navigate={~p"/channels"} class={@active == :channels && "active font-semibold"}>
                발행 채널
              </.link>
            </li>
            <li>
              <.link navigate={~p"/agent"} class={@active == :agent && "active font-semibold"}>
                에이전트
              </.link>
            </li>
            <li>
              <.link navigate={~p"/voices"} class={@active == :voices && "active font-semibold"}>
                목소리
              </.link>
            </li>
            <li>
              <.link navigate={~p"/settings"} class={@active == :settings && "active font-semibold"}>
                설정
              </.link>
            </li>
          </ul>
        </nav>

        <div class="mt-6 border-t border-base-300 px-4 pt-4 text-xs text-base-content/50">
          <div>조작은 MCP 로 한다.</div>
          <div class="mt-1">이 화면은 결과를 눈으로 보는 곳이다.</div>
          <div class="mt-3"><.theme_toggle /></div>
        </div>
      </aside>

      <div class="min-w-0 flex-1">
        <header class="border-b border-base-300 px-4 py-2 md:hidden">
          <div class="flex items-center gap-3">
            <a href="/" class="font-bold">videoTool</a>
            <.link navigate={~p"/"} class="text-sm">프로젝트</.link>
            <.link navigate={~p"/dashboard"} class="text-sm">성과</.link>
            <.link navigate={~p"/series"} class="text-sm">반복</.link>
            <.link navigate={~p"/prompts"} class="text-sm">프롬프트</.link>
            <.link navigate={~p"/channels"} class="text-sm">채널</.link>
            <.link navigate={~p"/agent"} class="text-sm">에이전트</.link>
            <.link navigate={~p"/voices"} class="text-sm">목소리</.link>
            <.link navigate={~p"/settings"} class="text-sm">설정</.link>
          </div>
        </header>

        <main class="px-4 py-6 sm:px-6 lg:px-8">
          <div class="mx-auto max-w-[1600px] space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
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
