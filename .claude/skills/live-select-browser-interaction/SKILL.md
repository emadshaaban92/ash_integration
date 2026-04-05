---
name: live-select-browser-interaction
description: How to interact with LiveSelect searchable dropdown components via browser_eval. Use this skill whenever you are navigating the application in the browser and encounter a LiveSelect dropdown — for example when verifying a change works correctly, reproducing a bug, or following user steps that involve selecting from a searchable dropdown. This is about browser interaction, not writing test code. Trigger this skill any time you need to use browser_eval to type into a LiveSelect search field and pick from its dynamically loaded list of results.
---

# Interacting with LiveSelect Components

LiveSelect is a searchable dropdown component used throughout this app. It renders as a text input that triggers a server-side search, then displays matching options in a dropdown list.

## DOM Structure

Each LiveSelect instance renders inside a `<div>` with an ID following the pattern:

```
#{field_name}_live_select_component
```

For example, a field named `product_0` produces: `_product_0_live_select_component`

Inside that container:
- A `<input>` with the configured placeholder (e.g. `"Search for a product..."`)
- A `<ul>` list of `<li>` options that appears after typing (each `<li>` contains a `<div>` with the option label)

## How to Select an Option

### Step 1: Type into the input to trigger the search

```js
const input = browser.locator('input[placeholder="Search for a product..."]');
await browser.fill(input, 'search term');
await browser.wait(2000); // Wait for server-side search + DOM update
```

### Step 2: Click an option from the dropdown

```js
// Click the first option's inner div
const firstOption = browser.locator('#_product_0_live_select_component li:first-child div');
await browser.click(firstOption);
```

Or use a snapshot to find the exact option:

```js
console.log('Options:', await browser.snapshot(
  browser.locator('#_product_0_live_select_component'), { limit: 20 }
));
// Then click by ref:
await browser.click(browser.getBySnapshotRef('e446'));
```

## Server-Side Event

The LiveView handles the search via a `"live_select_change"` event:

```elixir
def handle_event("live_select_change", %{"text" => text, "id" => live_select_id}, socket) do
  options = search_something(text)
  send_update(LiveSelect.Component, id: live_select_id, options: options)
  {:noreply, socket}
end
```

## Tips

- Always wait ~2 seconds after filling the input — the search is async (server roundtrip).
- The dropdown only appears after the minimum character threshold (typically 2 characters).
- To find the container ID, look for `[id*="live_select"]` elements on the page.
- The selected value is submitted as a hidden input with the field name.
