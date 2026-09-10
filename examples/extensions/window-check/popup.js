const api = globalThis.browser ?? globalThis.chrome;
const result = document.querySelector("#result");
const url = "https://example.com/";

const actions = {
  "new-tab": () => api.tabs.create({ url, active: true }),
  "background-tab": () => api.tabs.create({ url, active: false }),
  "new-window": () => api.windows.create({ url, focused: true }),
  "background-window": () => api.windows.create({ url, focused: false }),
  "blank-tab": () => api.tabs.create({}),
  inspect: async () => {
    const [tabs, windows] = await Promise.all([
      api.tabs.query({}),
      api.windows.getAll({ populate: true })
    ]);
    return {
      tabs: tabs.map(({ id, windowId, active, url, title }) => ({ id, windowId, active, url, title })),
      windows: windows.map(({ id, focused, tabs }) => ({ id, focused, tabIds: (tabs ?? []).map(tab => tab.id) }))
    };
  }
};

for (const [id, action] of Object.entries(actions)) {
  document.getElementById(id).addEventListener("click", async () => {
    result.textContent = "Working…";
    try {
      result.textContent = JSON.stringify(await action(), null, 2);
    } catch (error) {
      result.textContent = `Failed: ${error.message ?? String(error)}`;
    }
  });
}
