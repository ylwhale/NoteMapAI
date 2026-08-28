/*
 * Standalone browser companion for the native NoteMap AI app.
 * It intentionally has no framework or build step, so it can be deployed as
 * a static site from Vercel or Netlify. Core data is kept in localStorage.
 */

const STORAGE_KEY = "notemap-ai-web-state-v2";
const appView = document.querySelector("#app-view");
const toast = document.querySelector("#toast");
const importFile = document.querySelector("#import-file");

const templates = {
  study: {
    title: "Cognitive load study session",
    body: "Active recall is more effective than rereading. Spaced repetition improves long-term retention.\n\nAction: Make a short practice quiz. Review difficult cards tomorrow.\nQuestion: How long should each study block be?",
    theme: "Study"
  },
  project: {
    title: "NoteMap AI advisor demo",
    body: "Goal: Create a clear way for people to turn rough notes into a useful visual map.\n\nAction: Finish the browser preview. Test the core generation flow. Share a review link with the advisor.\nContext: The iOS app remains the primary product. The web version is a separate advisor-facing companion.\nQuestion: Which workflow should be prioritized next?",
    theme: "Project"
  },
  meeting: {
    title: "Team sync — product review",
    body: "The core interaction feels simple. The result should be easy to scan. The first-time experience needs a clear example.\n\nAction: Add a sample state. Write down the next milestone. Confirm the feedback deadline.\nQuestion: Which screen needs the most polish?",
    theme: "Meeting"
  }
};

function id(prefix = "id") {
  if (window.crypto && crypto.randomUUID) return `${prefix}-${crypto.randomUUID()}`;
  return `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function nowISO() { return new Date().toISOString(); }

const demoNoteTemplates = [
  ["First project direction", "Goal: make thinking visible without adding friction.\nAction: define the smallest useful browser workflow.\nQuestion: what should the advisor test first?", "Project", ["project", "idea"], "Home office", 41.878, -87.629, true],
  ["Active recall study session", "Active recall is more effective than rereading. Spaced repetition improves long-term retention.\nAction: make a short practice quiz and review difficult cards tomorrow.\nQuestion: how long should each study block be?", "Study", ["study", "memory"], "Campus library", 41.872, -87.649, false],
  ["Advisor feedback meeting", "The capture flow feels clear. The result should be easy to scan.\nAction: show a sample state before asking for a blank note.\nQuestion: which screen needs the most polish?", "Meeting", ["meeting", "feedback"], "Advisor office", 41.891, -87.624, true],
  ["Chicago museum ideas", "Possible weekend stops include the art museum and the science museum.\nAction: compare opening hours and travel time.\nQuestion: which place fits a half-day visit?", "Travel", ["travel", "research"], "Chicago", 41.879, -87.623, false],
  ["Retrieval design notes", "Relevant retrieval should search title, body, tags, dates, themes, and places.\nAction: rank exact matches before broader contextual matches.\nQuestion: how should vague queries be clarified?", "Research", ["research", "retrieval"], "Research desk", 40.748, -73.985, false],
  ["Morning capture habit", "A quick capture works best when the note can stay unfinished.\nAction: write one rough thought before checking messages.\nQuestion: what makes the habit easy to repeat?", "Daily", ["daily", "routine"], "Kitchen table", 40.751, -73.977, false],
  ["Web deployment checklist", "The web companion is a separate static site inside the web folder.\nAction: deploy with Root Directory web and no build command.\nQuestion: should the advisor review Vercel or Netlify first?", "Project", ["deploy", "web"], "Home office", 41.881, -87.638, true],
  ["Swift concurrency review", "Async work should remain cancellable and failures should be visible to the user.\nAction: review task cancellation and timeout behavior.\nQuestion: which service owns the timeout?", "Study", ["swift", "code"], "Engineering lab", 37.775, -122.419, false],
  ["Usability review notes", "People understand capture, but may not understand why evidence is selected before an answer.\nAction: explain the privacy boundary beside the Ask button.\nQuestion: is the consent language clear enough?", "Meeting", ["meeting", "usability"], "Design studio", 37.779, -122.414, false],
  ["Airport day plan", "Leave extra time for security and keep the boarding information easy to find.\nAction: save the itinerary and check the departure terminal.\nQuestion: what can be prepared the night before?", "Travel", ["travel", "plan"], "O'Hare", 41.974, -87.907, false],
  ["Privacy review", "AI requests should include only the question and selected excerpts. API keys belong in secure storage.\nAction: document the data boundary for reviewers.\nQuestion: which fields should never leave the device?", "Research", ["privacy", "research"], "Privacy lab", 42.36, -71.058, true],
  ["Plan source links", "A saved plan should preserve the source note IDs and show when a source changes or is deleted.\nAction: test a plan after editing its source note.\nQuestion: should changed sources show a warning?", "Project", ["plans", "sources"], "Home office", 42.355, -71.065, false],
  ["Weekly reflection", "This week had a lot of context switching. The useful pattern was writing down the next action immediately.\nAction: keep one visible priority each morning.\nQuestion: what should be removed from next week?", "Daily", ["daily", "reflection"], "Apartment", 34.052, -118.244, false],
  ["Spaced repetition plan", "Difficult cards should return sooner while mastered cards can wait longer.\nAction: group cards by confidence after each session.\nQuestion: which topics need another example?", "Study", ["study", "plan"], "Study room", 34.047, -118.25, false],
  ["Team sync milestone", "The browser demo needs to be useful for review while the native app stays unchanged.\nAction: verify the core flow on a fresh browser profile.\nQuestion: what feedback would change the next milestone?", "Meeting", ["meeting", "milestone"], "Team room", 47.606, -122.332, true],
  ["Weekend route", "A good route has two main stops and enough space for an unplanned stop.\nAction: put the stops in order and estimate walking time.\nQuestion: where should the route begin?", "Travel", ["travel", "route"], "Seattle", 47.61, -122.335, false],
  ["Semantic matching notes", "Keyword overlap is useful for a transparent baseline, while semantic matching handles related wording.\nAction: compare exact and contextual results.\nQuestion: what threshold avoids noisy evidence?", "Research", ["research", "semantic"], "ML lab", 37.334, -121.89, false],
  ["Advisor demo preparation", "The reviewer needs a simple path through capture, library, Ask, and plans.\nAction: create notes across several dates and themes.\nQuestion: which behavior should be explained in the demo?", "Project", ["demo", "advisor"], "Home office", 37.338, -121.886, true],
  ["Book notes", "A useful summary separates the author’s claim from my own reaction.\nAction: label quotations and follow-up questions.\nQuestion: which idea should be tested in practice?", "Daily", ["reading", "idea"], "Bookstore cafe", 39.952, -75.166, false],
  ["Exam topics", "The exam will cover retrieval, privacy, persistence, and interface states.\nAction: make one explanation for each topic.\nQuestion: which concept is still hardest to explain?", "Study", ["study", "exam"], "Lecture hall", 39.949, -75.19, false],
  ["Milestone decision", "A small static deployment is enough for advisor review before adding a server backend.\nAction: collect feedback on the workflow first.\nQuestion: what evidence would justify adding real AI?", "Meeting", ["decision", "feedback"], "Conference room", 40.443, -79.951, false],
  ["Restaurant ideas", "Choose one dependable option near the route and one backup with flexible seating.\nAction: check menus and reservation times.\nQuestion: which constraint matters most for the group?", "Travel", ["travel", "food"], "Pittsburgh", 40.441, -80.001, false],
  ["Evidence rubric", "A strong source has an excerpt, context, date, and a clear relation to the question.\nAction: review low-scoring sources before generating an answer.\nQuestion: how should conflicting notes be shown?", "Research", ["evidence", "research"], "Research desk", 38.907, -77.037, true],
  ["Release risks", "The largest risks are exposed credentials, unclear consent, and confusing empty states.\nAction: test each risk on a clean deployment.\nQuestion: which risk blocks sharing with an advisor?", "Project", ["release", "risk"], "Home office", 38.911, -77.043, false],
  ["Podcast idea", "Short episodes could explain one practical way to turn messy notes into a next action.\nAction: outline three episode topics.\nQuestion: who is the first listener?", "Daily", ["idea", "writing"], "Coffee shop", 39.739, -104.99, false],
  ["Writing outline", "Start with the problem, show the evidence, then explain the smallest working solution.\nAction: draft the introduction and one example.\nQuestion: where does the reader need more context?", "Study", ["writing", "study"], "Writing room", 39.742, -104.995, false],
  ["Design review", "The interface should feel calm, readable, and useful before it feels clever.\nAction: inspect mobile width and keyboard focus states.\nQuestion: which visual signal should indicate saved data?", "Meeting", ["design", "review"], "Design studio", 32.777, -96.797, false],
  ["Packing list", "Pack the essentials first, then leave room for weather changes and a small notebook.\nAction: check the forecast and weigh the bag.\nQuestion: what can be left behind?", "Travel", ["travel", "checklist"], "Dallas", 32.78, -96.8, false],
  ["Privacy language", "The disclosure should say what is selected, where it goes, and what is never sent.\nAction: read the copy aloud to someone unfamiliar with the app.\nQuestion: which phrase could be misunderstood?", "Research", ["privacy", "writing"], "Policy room", 30.267, -97.743, true],
  ["Final handoff", "The advisor should receive one stable link and a short explanation of what is native versus browser-based.\nAction: verify deployment settings and send the review URL.\nQuestion: what should be fixed before the final handoff?", "Project", ["handoff", "deploy"], "Home office", 30.271, -97.746, true]
];

function dateOnlyForOffset(offset) {
  const date = new Date(Date.now() - offset * 86400000);
  return date.toISOString().slice(0, 10);
}

function buildDemoNotes() {
  return demoNoteTemplates.map(([title, body, tripTheme, acceptedTags, place, latitude, longitude, isFavorite], index) => {
    const createdAt = new Date(Date.now() - (index % 30) * 86400000 - (index % 5) * 3600000).toISOString();
    return { id: `demo-note-${String(index + 1).padStart(2, "0")}`, title, body, createdAt, updatedAt: createdAt, eventDate: dateOnlyForOffset(index % 30), place, placeDetail: "Test fixture", latitude: String(latitude), longitude: String(longitude), acceptedTags, tripTheme, isFavorite };
  });
}

function defaultState() {
  return {
    activeTab: "home",
    notes: buildDemoNotes(),
    tagSuggestions: [], plans: [], history: [],
    preferences: { aiProcessingConsent: "undecided", model: "gpt-5.6-luna", keepLocalHistory: true },
    captureDraft: { title: "", body: "", eventDate: "", tripTheme: "" },
    askDraft: { question: "", filters: { tag: "", date: "any", place: "", theme: "", favoritesOnly: false } },
    library: { query: "", filters: { tag: "", date: "any", place: "", theme: "", favoritesOnly: false }, mode: "list" },
    editingNoteId: null, selectedPlanId: null, askSession: null, currentMap: null
  };
}

function loadState() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    if (!saved) return defaultState();
    const fresh = defaultState();
    return {
      ...fresh, ...saved,
      preferences: { ...fresh.preferences, ...(saved.preferences || {}) },
      captureDraft: { ...fresh.captureDraft, ...(saved.captureDraft || {}) },
      askDraft: { ...fresh.askDraft, ...(saved.askDraft || {}), filters: { ...fresh.askDraft.filters, ...((saved.askDraft || {}).filters || {}) } },
      library: { ...fresh.library, ...(saved.library || {}), filters: { ...fresh.library.filters, ...((saved.library || {}).filters || {}) } },
      notes: Array.isArray(saved.notes) ? saved.notes : fresh.notes,
      plans: Array.isArray(saved.plans) ? saved.plans : [],
      tagSuggestions: Array.isArray(saved.tagSuggestions) ? saved.tagSuggestions : [],
      history: Array.isArray(saved.history) ? saved.history : []
    };
  } catch { return defaultState(); }
}

let state = loadState();
let toastTimer;

function saveState() {
  const persisted = { ...state, askSession: null, currentMap: null };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(persisted));
}

function escapeHtml(value) {
  return String(value ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#039;");
}

function compact(value, max = 180) {
  const clean = String(value || "").replace(/\s+/g, " ").trim();
  return clean.length <= max ? clean : `${clean.slice(0, max - 1).trim()}…`;
}

function lines(value) {
  return String(value || "").split(/\n+/).map((line) => line.replace(/^\s*[-•*]\s*/, "").trim()).filter(Boolean);
}

function tokens(value) {
  return [...new Set(String(value || "").toLowerCase().match(/[a-z0-9][a-z0-9'-]*/g) || [])].filter((word) => word.length > 2);
}

function formatDate(value, includeTime = false) {
  if (!value) return "No date";
  const date = new Date(value.includes("T") ? value : `${value}T12:00:00`);
  if (Number.isNaN(date.getTime())) return "No date";
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", year: "numeric", ...(includeTime ? { hour: "numeric", minute: "2-digit" } : {}) }).format(date);
}

function dateValue(note) { return note.eventDate || note.createdAt; }

function unique(values) { return [...new Set(values.filter(Boolean))]; }

function allTags() { return unique(state.notes.flatMap((note) => note.acceptedTags || [])).sort(); }
function allPlaces() { return unique(state.notes.map((note) => note.place)).sort(); }
function allThemes() { return unique(state.notes.map((note) => note.tripTheme)).sort(); }

function matchesDate(value, filter) {
  if (!filter || filter === "any") return true;
  const date = new Date(value || 0).getTime();
  const days = filter === "today" ? 1 : filter === "sevenDays" ? 7 : 30;
  return Date.now() - date <= days * 86400000;
}

function matchesFilters(note, filters = {}) {
  const searchable = [note.title, note.body, ...(note.acceptedTags || []), note.place, note.placeDetail, note.tripTheme, note.eventDate].join(" ").toLowerCase();
  return (!filters.tag || (note.acceptedTags || []).includes(filters.tag)) &&
    (!filters.place || note.place === filters.place) &&
    (!filters.theme || note.tripTheme === filters.theme) &&
    (!filters.favoritesOnly || note.isFavorite) &&
    matchesDate(dateValue(note), filters.date) &&
    (!filters.query || searchable.includes(filters.query.toLowerCase().trim()));
}

function sortNewest(a, b) { return new Date(b.updatedAt || b.createdAt).getTime() - new Date(a.updatedAt || a.createdAt).getTime(); }

function showToast(message) {
  toast.textContent = message;
  toast.classList.add("visible");
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => toast.classList.remove("visible"), 2800);
}

function getInitials(value) { return String(value || "N").split(/\s+/).slice(0, 2).map((word) => word[0]).join("").toUpperCase(); }

function tagMarkup(tags = [], neutral = false) {
  return tags.length ? `<div class="tag-list">${tags.map((tag) => `<span class="tag${neutral ? " neutral" : ""}">#${escapeHtml(tag)}</span>`).join("")}</div>` : "";
}

function navMarkup() {
  const items = [["home", "⌂", "Home"], ["library", "▦", "Library"], ["ask", "?", "Ask"], ["plans", "✓", "Plans"], ["settings", "⚙", "Settings"]];
  return `<nav class="nav-tabs" aria-label="Primary navigation">${items.map(([key, icon, label]) => `<button class="nav-tab${state.activeTab === key ? " active" : ""}" data-tab="${key}" type="button"><span class="tab-icon" aria-hidden="true">${icon}</span>${label}</button>`).join("")}</nav>`;
}

function pageHeading(kicker, title, description = "") {
  return `<div class="page-heading"><div><p class="section-kicker">${escapeHtml(kicker)}</p><h2>${escapeHtml(title)}</h2>${description ? `<p class="muted">${escapeHtml(description)}</p>` : ""}</div></div>`;
}

function noteCard(note, compactCard = false) {
  return `<article class="note-card" data-note-card="${note.id}">
    <div class="note-card-top"><div><p class="mini-label">${escapeHtml(note.tripTheme || "Note")} · ${escapeHtml(formatDate(note.eventDate || note.createdAt))}</p><h3>${escapeHtml(note.title || "Untitled note")}</h3></div>
    <button class="star-button${note.isFavorite ? " selected" : ""}" data-action="toggle-favorite" data-note-id="${note.id}" type="button" aria-label="${note.isFavorite ? "Remove favorite" : "Add favorite"}">${note.isFavorite ? "★" : "☆"}</button></div>
    <p>${escapeHtml(compact(note.body, compactCard ? 115 : 190))}</p>
    ${tagMarkup(note.acceptedTags || [])}
    <div class="note-meta"><span>${note.place ? `⌖ ${escapeHtml(note.place)}` : "Local note"}</span><span>·</span><button class="action-link" data-action="edit-note" data-note-id="${note.id}" type="button">Open note</button></div>
  </article>`;
}

function planCard(plan) {
  const done = (plan.checklist || []).filter((item) => item.isComplete).length;
  return `<article class="plan-card${state.selectedPlanId === plan.id ? " selected" : ""}" data-action="select-plan" data-plan-id="${plan.id}">
    <div class="plan-card-top"><div><p class="mini-label">${escapeHtml(plan.provenanceLabel || "Saved plan")}</p><h3>${escapeHtml(plan.title || "Untitled plan")}</h3></div><span class="tag neutral">${done}/${(plan.checklist || []).length}</span></div>
    <p>${escapeHtml(compact(plan.conclusion || "", 145))}</p><div class="note-meta"><span>${formatDate(plan.updatedAt || plan.createdAt)}</span><span>·</span><span>${(plan.sourceNoteIDs || []).length} source${(plan.sourceNoteIDs || []).length === 1 ? "" : "s"}</span></div>
  </article>`;
}

function renderHome() {
  const recent = [...state.notes].sort(sortNewest).slice(0, 3);
  const recentPlans = [...state.plans].sort(sortNewest).slice(0, 2);
  const pending = state.tagSuggestions.filter((item) => item.decision === "pending");
  return `${heroMarkup()}${pageHeading("Workspace", "A calm place for your thinking", "Capture first. Find the useful thread later.")}
    <div class="stats-grid"><div class="stat"><strong>${state.notes.length}</strong><span>saved notes</span></div><div class="stat"><strong>${state.plans.length}</strong><span>saved plans</span></div><div class="stat"><strong>${allTags().length}</strong><span>accepted tags</span></div></div>
    <div class="section-heading"><p class="section-kicker">01 / Capture</p><h2>Start with what’s on your mind.</h2></div>
    <div class="content-grid"><div class="panel panel-pad">${captureFormMarkup()}</div><aside class="capture-side"><p class="section-kicker">Quick capture</p><h3>Keep the rough edges.</h3><p>The browser version mirrors the mobile workflow: save notes locally, add context, then ask grounded questions against the notes you selected.</p><div class="mini-list"><div><b>1</b><span>Write without organizing first.</span></div><div><b>2</b><span>Review suggested tags.</span></div><div><b>3</b><span>Turn evidence into a plan.</span></div></div></aside></div>
    ${pending.length ? `<div class="section-heading"><p class="section-kicker">02 / Review</p><h2>Tag suggestions</h2></div><div class="panel panel-pad"><div class="tag-suggestion-list">${pending.map(suggestionCard).join("")}</div></div>` : ""}
    <div class="section-heading"><p class="section-kicker">03 / Recent</p><h2>Notes to pick back up.</h2></div>
    <div class="home-columns"><div>${recent.length ? `<div class="note-list">${recent.map((note) => noteCard(note, true)).join("")}</div>` : emptyState("No notes yet", "Your saved notes will appear here.", "home")}</div><div class="panel panel-pad"><div class="panel-header"><div><h3>Saved plans</h3><p>Keep useful conclusions close.</p></div><button class="action-link" data-tab="plans" type="button">View all</button></div>${recentPlans.length ? `<div class="plan-list">${recentPlans.map(planCard).join("")}</div>` : `<p class="muted">No plans saved yet. Ask a question when you have a few notes.</p>`}</div></div>`;
}

function heroMarkup() {
  return `<section class="hero" aria-labelledby="hero-title"><div class="hero-copy"><p class="eyebrow">Turn notes into direction</p><h1 id="hero-title">See the shape of your thinking.</h1><p class="hero-description">A separate web companion for the NoteMap AI iOS app. Capture notes, search your local library, review evidence, and save grounded plans.</p><div class="hero-points"><span><i>↗</i> Local library</span><span><i>✓</i> Grounded plans</span><span><i>?</i> Evidence first</span></div></div><div class="hero-note"><span class="note-pin"></span><p class="note-label">A clearer way forward</p><p class="note-quote">“The map is not the answer. It is the moment the answer becomes visible.”</p><div class="note-lines"><span></span><span></span><span></span></div></div></section>`;
}

function captureFormMarkup(note = null) {
  const editing = Boolean(note);
  const data = note || state.captureDraft;
  return `<form class="capture-form" data-form="${editing ? "edit-note" : "capture"}">${editing ? `<input type="hidden" name="noteId" value="${note.id}" />` : ""}
    <div class="field-row"><label class="field"><span class="field-label">Title</span><input name="title" value="${escapeHtml(data.title || "")}" placeholder="A short title" maxlength="120" /></label><label class="field"><span class="field-label">Theme</span><input name="tripTheme" value="${escapeHtml(data.tripTheme || "")}" placeholder="Study, travel, project…" maxlength="80" /></label></div>
    <label class="field"><span class="field-label">Note body <span class="muted">(required)</span></span><textarea name="body" id="${editing ? "edit-body" : "capture-body"}" required placeholder="Write a thought, meeting note, source, or project idea…">${escapeHtml(data.body || "")}</textarea><span class="input-meta"><span>Saved locally in this browser</span><span data-character-count>${String(data.body || "").length} characters</span></span></label>
    <div class="field-row"><label class="field"><span class="field-label">Event date</span><input name="eventDate" type="date" value="${escapeHtml(data.eventDate || "")}" /></label><label class="field"><span class="field-label">Place or context</span><input name="place" value="${escapeHtml(data.place || "")}" placeholder="Optional place" maxlength="100" /></label></div>
    <div class="field-row"><label class="field"><span class="field-label">Place detail</span><input name="placeDetail" value="${escapeHtml(data.placeDetail || "")}" placeholder="Room, neighborhood, or extra context" maxlength="140" /></label><label class="field"><span class="field-label">Coordinates <span class="muted">(optional)</span></span><div class="field-row"><input name="latitude" type="number" step="any" value="${escapeHtml(data.latitude || "")}" placeholder="Latitude" /><input name="longitude" type="number" step="any" value="${escapeHtml(data.longitude || "")}" placeholder="Longitude" /></div></label></div>
    <label class="field"><span class="field-label">Tags, comma separated</span><input name="tags" value="${escapeHtml((data.acceptedTags || []).join(", "))}" placeholder="research, follow-up, idea" /></label>
    ${editing ? `<label class="setting-row"><span class="setting-copy"><strong>Favorite note</strong><span>Keep this note easy to find in Library.</span></span><span class="switch"><input name="isFavorite" type="checkbox" ${data.isFavorite ? "checked" : ""} /><span></span></span></label>` : ""}
    <div class="button-row"><button class="primary-button" type="submit">${editing ? "Save changes" : "Save note"}</button>${editing ? `<button class="danger-button" data-action="delete-note" data-note-id="${note.id}" type="button">Delete note</button><button class="text-button" data-action="cancel-edit" type="button">Cancel</button>` : `<button class="secondary-button" data-action="clear-capture" type="button">Clear</button>`}</div>
    ${!editing ? `<div class="template-row"><span class="muted">Try an example:</span>${Object.keys(templates).map((key) => `<button class="chip-button" data-action="load-template" data-template="${key}" type="button">${key}</button>`).join("")}</div>` : ""}
  </form>`;
}

function suggestionCard(suggestion) {
  const note = state.notes.find((item) => item.id === suggestion.noteID);
  if (!note) return "";
  return `<div class="suggestion-card"><div><strong>${escapeHtml(note.title)}</strong><p>Suggested from your note: ${escapeHtml(compact(note.body, 80))}</p><div class="suggestion-tags" style="margin-top:8px">${suggestion.tags.map((tag) => `<span class="tag">#${escapeHtml(tag)}</span>`).join("")}</div></div><div class="button-row"><button class="secondary-button" data-action="accept-suggestion" data-suggestion-id="${suggestion.id}" type="button">Accept</button><button class="text-button" data-action="dismiss-suggestion" data-suggestion-id="${suggestion.id}" type="button">Dismiss</button></div></div>`;
}

function emptyState(title, text, tab = "home") {
  return `<div class="empty-state"><strong>${escapeHtml(title)}</strong><span>${escapeHtml(text)}</span><div class="button-row"><button class="secondary-button" data-tab="${tab === "home" ? "library" : "home"}" type="button">${tab === "home" ? "Open library" : "Back home"}</button></div></div>`;
}

function renderLibrary() {
  const editing = state.notes.find((note) => note.id === state.editingNoteId);
  if (editing) {
    return `${pageHeading("Library / Edit", "Update note context", "Keep the note, metadata, and source context together.")}<div class="panel panel-pad">${captureFormMarkup(editing)}</div>`;
  }
  const filtered = state.notes.filter((note) => matchesFilters(note, { ...state.library.filters, query: state.library.query })).sort(sortNewest);
  return `${pageHeading("Library", "Your notes, with context", "Search across titles, bodies, tags, dates, places, and themes.")}
    <div class="panel panel-pad"><div class="toolbar"><label class="search-field"><span class="visually-hidden">Search library</span><input id="library-search" value="${escapeHtml(state.library.query)}" placeholder="Search your notes…" /></label><div class="view-toggle"><button class="${state.library.mode === "list" ? "active" : ""}" data-action="library-mode" data-mode="list" type="button">List</button><button class="${state.library.mode === "cards" ? "active" : ""}" data-action="library-mode" data-mode="cards" type="button">Cards</button><button class="${state.library.mode === "map" ? "active" : ""}" data-action="library-mode" data-mode="map" type="button">Map</button></div></div>${filterMarkup("library")}
    <div id="library-results">${renderLibraryResults(filtered)}</div></div>`;
}

function filterMarkup(prefix) {
  const filters = state[prefix].filters;
  return `<div class="filter-grid"><label><span class="field-label">Tag</span><select data-filter-prefix="${prefix}" data-filter="tag"><option value="">All tags</option>${allTags().map((tag) => `<option value="${escapeHtml(tag)}" ${filters.tag === tag ? "selected" : ""}>#${escapeHtml(tag)}</option>`).join("")}</select></label><label><span class="field-label">Date</span><select data-filter-prefix="${prefix}" data-filter="date"><option value="any" ${filters.date === "any" ? "selected" : ""}>Any time</option><option value="today" ${filters.date === "today" ? "selected" : ""}>Today</option><option value="sevenDays" ${filters.date === "sevenDays" ? "selected" : ""}>Last 7 days</option><option value="thirtyDays" ${filters.date === "thirtyDays" ? "selected" : ""}>Last 30 days</option></select></label><label><span class="field-label">Place</span><select data-filter-prefix="${prefix}" data-filter="place"><option value="">All places</option>${allPlaces().map((place) => `<option value="${escapeHtml(place)}" ${filters.place === place ? "selected" : ""}>${escapeHtml(place)}</option>`).join("")}</select></label><label><span class="field-label">Theme</span><select data-filter-prefix="${prefix}" data-filter="theme"><option value="">All themes</option>${allThemes().map((theme) => `<option value="${escapeHtml(theme)}" ${filters.theme === theme ? "selected" : ""}>${escapeHtml(theme)}</option>`).join("")}</select></label></div><label class="setting-row" style="border-top:0;padding-top:0"><span class="setting-copy"><strong>Favorites only</strong><span>Show only notes marked as favorites.</span></span><span class="switch"><input type="checkbox" data-filter-prefix="${prefix}" data-filter="favoritesOnly" ${filters.favoritesOnly ? "checked" : ""} /><span></span></span></label>`;
}

function renderLibraryResults(filtered = state.notes) {
  if (!filtered.length) return emptyState("No matching notes", "Try clearing a filter, changing the search, or create a new note.", "library");
  if (state.library.mode === "map") return renderMapView(filtered);
  const cards = filtered.map((note) => noteCard(note)).join("");
  return state.library.mode === "cards" ? `<div class="note-grid">${cards}</div>` : `<div class="note-list">${cards}</div>`;
}

function renderMapView(notes) {
  const located = notes.filter((note) => note.latitude !== "" && note.longitude !== "");
  if (!located.length) return `<div class="empty-state"><strong>No located notes</strong><span>Add a place name to a note to see it in this browser map view.</span><div class="button-row"><button class="secondary-button" data-action="first-note-edit" type="button">Add context to a note</button></div></div>`;
  const minLat = Math.min(...located.map((note) => Number(note.latitude))), maxLat = Math.max(...located.map((note) => Number(note.latitude))), minLon = Math.min(...located.map((note) => Number(note.longitude))), maxLon = Math.max(...located.map((note) => Number(note.longitude)));
  const latSpan = maxLat - minLat || 1, lonSpan = maxLon - minLon || 1;
  const dots = located.map((note) => { const left = 12 + ((Number(note.longitude) - minLon) / lonSpan) * 76; const top = 88 - ((Number(note.latitude) - minLat) / latSpan) * 76; return `<button class="map-dot" style="left:${left}%;top:${top}%" title="${escapeHtml(note.title)}" data-action="edit-note" data-note-id="${note.id}" aria-label="Open ${escapeHtml(note.title)}"></button>`; }).join("");
  return `<div class="map-view"><div class="coordinate-map" aria-label="Local coordinate plot of located notes">${dots}</div><div class="located-list"><p class="mini-label">Located notes</p>${located.map((note) => `<button type="button" data-action="edit-note" data-note-id="${note.id}"><strong>${escapeHtml(note.title)}</strong><span>${escapeHtml(note.place || "Coordinates saved")}</span></button>`).join("")}</div></div>`;
}

function renderAsk() {
  const session = state.askSession;
  return `${pageHeading("Ask", "Find the thread in your notes", "Search happens locally first. Review the evidence, then create a grounded conclusion.")}
    <div class="ask-layout"><div class="panel panel-pad"><form class="ask-form" data-form="ask"><label class="field"><span class="field-label">Your question</span><textarea name="question" required placeholder="What should I focus on next?">${escapeHtml(state.askDraft.question)}</textarea></label>${filterMarkup("askDraft")}<div class="info-banner"><strong>Privacy boundary.</strong> The browser searches your local notes. This demo does not send your library or API key anywhere.</div><button class="primary-button" type="submit">Search relevant notes <span aria-hidden="true">→</span></button></form></div><div id="ask-result">${session ? renderAskSession(session) : `<div class="panel panel-pad empty-state"><strong>Ask a question when you’re ready.</strong><span>Relevant notes will appear here for you to select before a conclusion is generated.</span></div>`}</div></div>`;
}

function renderAskSession(session) {
  if (session.phase === "noEvidence") return `<div class="panel panel-pad"><span class="phase-label">No evidence</span><div class="empty-state"><strong>Nothing matched this question yet.</strong><span>Try a broader question or remove one of the filters.</span></div></div>`;
  if (session.phase === "consent") return `<div class="panel panel-pad"><span class="phase-label">First-use review</span>${consentBanner()}<button class="secondary-button" data-action="back-to-evidence" type="button">Back to evidence</button></div>`;
  const sources = session.sources || [];
  return `<div class="panel panel-pad"><div class="panel-header"><div><span class="phase-label">Evidence review</span><h3 style="margin-top:9px">${sources.length} relevant source${sources.length === 1 ? "" : "s"}</h3><p>Select the notes you want the conclusion to use. This mirrors the iOS evidence-selection step.</p></div></div><div class="source-list">${sources.map(sourceCard).join("")}</div><div class="ask-actions"><button class="text-button" data-action="clear-ask" type="button">Start over</button><button class="primary-button" data-action="generate-conclusion" type="button">Generate grounded conclusion →</button></div>${session.conclusion ? renderConclusion(session.conclusion) : ""}</div>`;
}

function consentBanner() {
  return `<div class="consent-banner"><strong>Allow conclusion generation?</strong><p>This browser demo keeps searching local. In a production version, only your question and the selected excerpts would be sent to your configured AI endpoint—not your full library.</p><div class="button-row"><button class="primary-button" data-action="accept-consent" type="button">Allow selected excerpts</button><button class="secondary-button" data-action="decline-consent" type="button">Do not allow</button></div></div>`;
}

function sourceCard(source) {
  return `<article class="source-card${source.selected ? " selected" : ""}"><div class="source-card-header"><input type="checkbox" data-action="toggle-source" data-source-id="${source.id}" ${source.selected ? "checked" : ""} aria-label="Use ${escapeHtml(source.title)} as evidence" /><div style="flex:1"><h3>${escapeHtml(source.title)}</h3><div class="source-context"><span>${escapeHtml(formatDate(source.date))}</span>${source.place ? `<span>⌖ ${escapeHtml(source.place)}</span>` : ""}${source.tags.length ? `<span>${source.tags.map((tag) => `#${escapeHtml(tag)}`).join(" ")}</span>` : ""}</div></div><span class="source-score">${Math.round(source.score * 100)}%</span></div><p>“${escapeHtml(source.excerpt)}”</p></article>`;
}

function renderConclusion(conclusion) {
  return `<div class="conclusion" style="margin-top:20px"><span class="phase-label">Grounded demo conclusion</span><h3>${escapeHtml(conclusion.directAnswer)}</h3>${(conclusion.answerParts || []).map((part) => `<div class="answer-part"><p>${escapeHtml(part)}</p></div>`).join("")}<div class="conclusion-columns"><div class="conclusion-box"><h4>Claims</h4><ul>${conclusion.claims.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul></div><div class="conclusion-box"><h4>Suggested checklist</h4><ul>${conclusion.checklist.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul></div></div>${conclusion.missingInformation.length ? `<div class="conclusion-box" style="margin-top:14px"><h4>Missing information</h4><ul>${conclusion.missingInformation.map((item) => `<li>${escapeHtml(item)}</li>`).join("")}</ul></div>` : ""}<div class="evidence-quote"><strong>Evidence used:</strong> ${conclusion.evidence.map((item) => `${escapeHtml(item.title)} — “${escapeHtml(item.excerpt)}”`).join(" · ")}</div><div class="button-row" style="margin-top:16px"><button class="primary-button" data-action="save-plan" type="button">Save as plan</button><button class="secondary-button" data-action="copy-conclusion" type="button">Copy conclusion</button></div></div>`;
}

function retrieve(question, filters) {
  const queryTerms = tokens(question);
  const temporal = /today|now|recent|latest|this week|last week|yesterday/i.test(question) ? "sevenDays" : "any";
  return state.notes.filter((note) => matchesFilters(note, filters)).map((note) => {
    const text = [note.title, note.body, ...(note.acceptedTags || []), note.place, note.tripTheme].join(" ").toLowerCase();
    const hits = queryTerms.filter((term) => text.includes(term));
    const exactBonus = text.includes(String(question).toLowerCase().trim()) ? .25 : 0;
    const timeBonus = temporal !== "any" && matchesDate(dateValue(note), temporal) ? .12 : 0;
    const score = Math.min(.99, (hits.length / Math.max(queryTerms.length, 1)) * .7 + exactBonus + timeBonus + (hits.length ? .18 : 0));
    return { id: `source-${note.id}`, noteID: note.id, title: note.title || "Untitled note", date: dateValue(note), place: note.place || "", tags: note.acceptedTags || [], excerpt: compact(note.body, 220), score };
  }).filter((source) => source.score >= (queryTerms.length ? .12 : 0)).sort((a, b) => b.score - a.score).slice(0, 20);
}

function buildConclusion(session) {
  const evidence = session.sources.filter((source) => source.selected);
  const sentences = evidence.flatMap((source) => lines(source.excerpt)).filter(Boolean);
  const actions = sentences.filter((sentence) => /\b(action|todo|next|finish|build|test|review|make|create|add|send|confirm|write|schedule)\b/i.test(sentence));
  const questions = sentences.filter((sentence) => /\?|\b(question|unclear|which|what should|how|who)\b/i.test(sentence));
  const focus = compact(actions[0] || sentences[0] || "Review the selected evidence and choose one concrete next step.", 140);
  return {
    directAnswer: `Start with ${focus.replace(/[.!?]$/, "")}.`,
    answerParts: [
      `The selected notes point toward a focused next step rather than a broad rewrite.`,
      evidence.length > 1 ? `That direction is supported by ${evidence.length} local sources, so you can keep the context visible while acting.` : `Use the selected note as the working context and add another source if the decision needs more support.`
    ],
    claims: [
      `The question is connected to ${evidence.map((source) => source.title).join(", ")}.`,
      actions.length ? `At least one action is already present in the evidence.` : `The evidence contains an idea, but no explicit action yet.`
    ],
    checklist: unique([...(actions.length ? actions.slice(0, 3) : ["Write one concrete next action"]), ...(questions.length ? [`Resolve: ${compact(questions[0], 110)}`] : [])]),
    missingInformation: questions.length ? questions.slice(0, 2) : ["A deadline or success measure is not stated."],
    evidence: evidence.map((source) => ({ title: source.title, excerpt: source.excerpt })),
    sourceNoteIDs: evidence.map((source) => source.noteID)
  };
}

function renderPlans() {
  const selected = state.plans.find((plan) => plan.id === state.selectedPlanId) || state.plans[0];
  if (selected && !state.selectedPlanId) state.selectedPlanId = selected.id;
  return `${pageHeading("Plans", "Keep the next step visible", "Plans preserve their checklist and source links so you can revisit the reasoning later.")}<div class="plans-layout"><div class="panel panel-pad"><div class="panel-header"><div><h3>Saved plans</h3><p>${state.plans.length} plan${state.plans.length === 1 ? "" : "s"}</p></div></div>${state.plans.length ? `<div class="plan-list">${state.plans.sort(sortNewest).map(planCard).join("")}</div>` : emptyState("No plans yet", "Save a grounded conclusion from Ask to create one.", "plans")}</div><div id="plan-editor">${selected ? renderPlanEditor(selected) : `<div class="panel panel-pad empty-state"><strong>Your next plan will appear here.</strong><span>Ask a question against your saved notes, then save the conclusion.</span></div>`}</div></div>`;
}

function renderPlanEditor(plan) {
  const linked = (plan.sourceNoteIDs || []).map((noteID) => state.notes.find((note) => note.id === noteID)).filter(Boolean);
  return `<div class="panel panel-pad"><form class="plan-editor" data-form="plan"><input type="hidden" name="planId" value="${plan.id}" /><label class="field"><span class="field-label">Plan title</span><input name="title" value="${escapeHtml(plan.title)}" required /></label><label class="field"><span class="field-label">Conclusion</span><textarea name="conclusion" rows="5">${escapeHtml(plan.conclusion)}</textarea></label><div><p class="field-label" style="margin-bottom:8px">Checklist</p><div class="checklist">${(plan.checklist || []).map((item, index) => `<label class="check-item${item.isComplete ? " done" : ""}"><input type="checkbox" data-action="toggle-checklist" data-plan-id="${plan.id}" data-index="${index}" ${item.isComplete ? "checked" : ""} /><span>${escapeHtml(item.text)}</span></label>`).join("")}</div></div><div><p class="field-label" style="margin-bottom:8px">Source links</p><div class="source-links">${linked.length ? linked.map((note) => `<div class="source-link">${escapeHtml(note.title)} · ${formatDate(dateValue(note))}</div>`).join("") : `<div class="source-link">No surviving source links.</div>`}</div></div><div class="button-row"><button class="primary-button" type="submit">Save plan</button><button class="secondary-button" data-action="share-plan" data-plan-id="${plan.id}" type="button">Share preview</button><button class="danger-button" data-action="delete-plan" data-plan-id="${plan.id}" type="button">Delete plan</button></div></form></div>`;
}

function renderSettings() {
  const pref = state.preferences;
  return `${pageHeading("Settings", "Keep control of your data", "The browser companion is local-first. No OpenAI key is stored by this static demo.")}<div class="settings-list"><section class="settings-card"><h3>AI processing consent</h3><p>For the production mobile flow, this controls whether selected excerpts may be sent to the configured AI provider. The current static web version generates a clearly labelled local demo conclusion.</p><div class="consent-options"><label class="consent-option"><input type="radio" name="consent" data-setting="consent" value="undecided" ${pref.aiProcessingConsent === "undecided" ? "checked" : ""} /><span><strong>Ask before first use</strong><span>Recommended while reviewing the app.</span></span></label><label class="consent-option"><input type="radio" name="consent" data-setting="consent" value="accepted" ${pref.aiProcessingConsent === "accepted" ? "checked" : ""} /><span><strong>Allow selected excerpts</strong><span>Only the question and selected evidence would be eligible for a future provider endpoint.</span></span></label><label class="consent-option"><input type="radio" name="consent" data-setting="consent" value="declined" ${pref.aiProcessingConsent === "declined" ? "checked" : ""} /><span><strong>Do not allow</strong><span>Keep the workflow local-only.</span></span></label></div></section><section class="settings-card"><h3>Model and history</h3><p>These preferences mirror the mobile app without exposing credentials in a browser.</p><div class="setting-row"><span class="setting-copy"><strong>Model label</strong><span>Used as a display preference until a secure server endpoint is connected.</span></span><select data-setting="model" style="max-width:210px"><option value="gpt-5.6-luna" ${pref.model === "gpt-5.6-luna" ? "selected" : ""}>gpt-5.6-luna</option><option value="gpt-5.6" ${pref.model === "gpt-5.6" ? "selected" : ""}>gpt-5.6</option><option value="custom" ${pref.model === "custom" ? "selected" : ""}>Custom</option></select></div><div class="setting-row"><span class="setting-copy"><strong>Keep local query history</strong><span>Store past questions in this browser for review.</span></span><span class="switch"><input type="checkbox" data-setting="history" ${pref.keepLocalHistory ? "checked" : ""} /><span></span></span></div><div class="button-row" style="margin-top:13px"><button class="secondary-button" data-action="clear-history" type="button">Clear query history</button><button class="secondary-button" data-action="export-archive" type="button">Export local data</button><button class="secondary-button" data-action="import-archive" type="button">Import local data</button></div></section><section class="settings-card"><h3>Privacy boundary</h3><ul class="privacy-list"><li>Notes, plans, tags, and history are stored in this browser’s local storage.</li><li>The static demo makes no AI or analytics request.</li><li>The iOS app’s Keychain, widget, share extension, system capture, and native location permissions are not available to a static web page.</li><li>For real AI generation on the web, add a server-side endpoint and keep the provider key there—not in browser code.</li></ul></section><section class="settings-card"><h3>Reset</h3><p>Use this only if you want to remove the local web companion data from this browser.</p><button class="danger-button" data-action="delete-all" type="button">Delete all web data</button></section></div>`;
}

function renderApp() {
  const page = state.activeTab === "library" ? renderLibrary() : state.activeTab === "ask" ? renderAsk() : state.activeTab === "plans" ? renderPlans() : state.activeTab === "settings" ? renderSettings() : renderHome();
  appView.innerHTML = `${navMarkup()}${page}`;
}

function createTagSuggestion(note) {
  const candidates = unique([...tokens(note.title), ...tokens(note.body)].filter((word) => ["study", "project", "meeting", "travel", "research", "idea", "follow-up", "action", "question", "demo", "work"].includes(word))).slice(0, 3);
  const existing = new Set(note.acceptedTags || []);
  const tags = candidates.filter((tag) => !existing.has(tag));
  if (!tags.length) return;
  state.tagSuggestions.unshift({ id: id("suggestion"), noteID: note.id, tags, createdAt: nowISO(), decision: "pending" });
}

function createNote(formData) {
  const body = String(formData.get("body") || "").trim();
  if (!body) return showToast("A note needs a body before it can be saved.");
  const createdAt = nowISO();
  const note = { id: id("note"), title: String(formData.get("title") || "").trim() || compact(lines(body)[0] || "Untitled note", 80), body, createdAt, updatedAt: createdAt, eventDate: String(formData.get("eventDate") || ""), place: String(formData.get("place") || "").trim(), placeDetail: String(formData.get("placeDetail") || "").trim(), latitude: String(formData.get("latitude") || "").trim(), longitude: String(formData.get("longitude") || "").trim(), acceptedTags: String(formData.get("tags") || "").split(",").map((tag) => tag.trim().toLowerCase()).filter(Boolean), tripTheme: String(formData.get("tripTheme") || "").trim(), isFavorite: false };
  state.notes.unshift(note);
  createTagSuggestion(note);
  state.captureDraft = { title: "", body: "", eventDate: "", tripTheme: "" };
  saveState(); renderApp(); showToast("Note saved locally.");
}

function updateNote(formData) {
  const note = state.notes.find((item) => item.id === formData.get("noteId"));
  const body = String(formData.get("body") || "").trim();
  if (!note || !body) return showToast("A note needs a body before it can be saved.");
  note.title = String(formData.get("title") || "").trim() || compact(lines(body)[0] || "Untitled note", 80);
  note.body = body; note.updatedAt = nowISO(); note.eventDate = String(formData.get("eventDate") || ""); note.place = String(formData.get("place") || "").trim(); note.placeDetail = String(formData.get("placeDetail") || "").trim(); note.latitude = String(formData.get("latitude") || "").trim(); note.longitude = String(formData.get("longitude") || "").trim(); note.tripTheme = String(formData.get("tripTheme") || "").trim(); note.acceptedTags = String(formData.get("tags") || "").split(",").map((tag) => tag.trim().toLowerCase()).filter(Boolean); note.isFavorite = formData.get("isFavorite") === "on";
  state.editingNoteId = null; createTagSuggestion(note); saveState(); renderApp(); showToast("Note updated.");
}

function deleteNote(noteID) {
  if (!window.confirm("Delete this note? Its saved source links will be removed from plans.")) return;
  state.notes = state.notes.filter((note) => note.id !== noteID);
  state.tagSuggestions = state.tagSuggestions.filter((suggestion) => suggestion.noteID !== noteID);
  state.history = state.history.filter((item) => !(item.sourceNoteIDs || []).includes(noteID));
  state.plans = state.plans.map((plan) => ({ ...plan, sourceNoteIDs: (plan.sourceNoteIDs || []).filter((idValue) => idValue !== noteID) }));
  state.editingNoteId = null; saveState(); renderApp(); showToast("Note deleted.");
}

function openEdit(noteID) { state.activeTab = "library"; state.editingNoteId = noteID; renderApp(); window.setTimeout(() => document.querySelector("#edit-body")?.focus(), 0); }

function doAsk(formData) {
  state.askDraft.question = String(formData.get("question") || "").trim();
  if (!state.askDraft.question) return showToast("Ask a question first.");
  const filters = state.askDraft.filters;
  const found = retrieve(state.askDraft.question, filters);
  if (!found.length) state.askSession = { phase: "noEvidence", sources: [] };
  else state.askSession = { phase: "review", sources: found.map((source, index) => ({ ...source, selected: index < Math.min(3, found.length) })) };
  saveState(); renderApp();
}

function toggleSource(sourceID) {
  if (!state.askSession) return;
  const source = state.askSession.sources.find((item) => item.id === sourceID);
  if (source) source.selected = !source.selected;
  renderApp();
}

function generateConclusion() {
  if (!state.askSession) return;
  if (state.preferences.aiProcessingConsent === "declined") { showToast("AI processing is disabled in Settings."); return; }
  if (state.preferences.aiProcessingConsent === "undecided") { state.askSession.phase = "consent"; renderApp(); return; }
  if (!state.askSession.sources.some((source) => source.selected)) return showToast("Select at least one evidence source.");
  state.askSession.phase = "complete";
  state.askSession.conclusion = buildConclusion(state.askSession);
  if (state.preferences.keepLocalHistory) state.history.unshift({ id: id("history"), question: state.askDraft.question, answerSummary: state.askSession.conclusion.directAnswer, sourceCount: state.askSession.conclusion.sourceNoteIDs.length, sourceNoteIDs: state.askSession.conclusion.sourceNoteIDs, createdAt: nowISO() });
  state.history = state.history.slice(0, 50); saveState(); renderApp(); showToast("Grounded demo conclusion created.");
}

function createPlan() {
  const conclusion = state.askSession?.conclusion;
  if (!conclusion) return;
  const plan = { id: id("plan"), title: state.askDraft.question || "Saved NoteMap plan", conclusion: conclusion.directAnswer, checklist: conclusion.checklist.map((text) => ({ id: id("check"), text, isComplete: false })), sourceNoteIDs: conclusion.sourceNoteIDs, provenanceLabel: "Grounded demo plan", createdAt: nowISO(), updatedAt: nowISO() };
  state.plans.unshift(plan); state.selectedPlanId = plan.id; state.activeTab = "plans"; saveState(); renderApp(); showToast("Plan saved locally.");
}

function copyText(value, success = "Copied to clipboard.") {
  if (!navigator.clipboard) return showToast("Clipboard access is unavailable in this browser.");
  navigator.clipboard.writeText(value).then(() => showToast(success)).catch(() => showToast("Clipboard access is unavailable in this browser."));
}

function conclusionText() {
  const conclusion = state.askSession?.conclusion;
  if (!conclusion) return "";
  return [conclusion.directAnswer, ...conclusion.answerParts, "Checklist:", ...conclusion.checklist.map((item) => `- ${item}`), "Evidence:", ...conclusion.evidence.map((item) => `- ${item.title}: ${item.excerpt}`)].join("\n");
}

function planShareText(plan) {
  return [`${plan.title}`, "", plan.conclusion, "", "Checklist:", ...(plan.checklist || []).map((item) => `${item.isComplete ? "[x]" : "[ ]"} ${item.text}`), "", `Sources: ${(plan.sourceNoteIDs || []).length}`].join("\n");
}

function exportArchive() {
  const archive = { schemaVersion: 1, exportedAt: nowISO(), notes: state.notes, tagSuggestions: state.tagSuggestions, plans: state.plans, queryHistory: state.history, preferences: state.preferences };
  const blob = new Blob([JSON.stringify(archive, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob); const link = document.createElement("a"); link.href = url; link.download = "notemap-ai-web-export.json"; link.click(); URL.revokeObjectURL(url); showToast("Local data exported.");
}

function importArchive(file) {
  const reader = new FileReader();
  reader.onload = () => { try { const archive = JSON.parse(reader.result); if (!Array.isArray(archive.notes)) throw new Error("Invalid archive"); state.notes = archive.notes; state.tagSuggestions = archive.tagSuggestions || []; state.plans = archive.plans || []; state.history = archive.queryHistory || []; state.preferences = { ...state.preferences, ...(archive.preferences || {}) }; saveState(); renderApp(); showToast("Local data imported."); } catch { showToast("That file is not a valid NoteMap AI export."); } };
  reader.readAsText(file);
}

function updateLibraryResults() {
  const results = document.querySelector("#library-results");
  if (results) results.innerHTML = renderLibraryResults(state.notes.filter((note) => matchesFilters(note, { ...state.library.filters, query: state.library.query })).sort(sortNewest));
}

appView.addEventListener("click", (event) => {
  const tabTarget = event.target.closest("[data-tab]");
  if (tabTarget) { state.activeTab = tabTarget.dataset.tab; state.editingNoteId = null; renderApp(); return; }
  const action = event.target.closest("[data-action]");
  if (!action) return;
  const kind = action.dataset.action;
  if (kind === "clear-capture") { const form = document.querySelector('[data-form="capture"]'); form?.reset(); showToast("Capture cleared."); }
  if (kind === "load-template") { const template = templates[action.dataset.template]; const form = document.querySelector('[data-form="capture"]'); if (form && template) { form.elements.title.value = template.title; form.elements.body.value = template.body; form.elements.tripTheme.value = template.theme; form.querySelector("[data-character-count]").textContent = `${template.body.length} characters`; showToast("Example loaded. Edit it or save it as a note."); } }
  if (kind === "edit-note") openEdit(action.dataset.noteId);
  if (kind === "cancel-edit") { state.editingNoteId = null; renderApp(); }
  if (kind === "toggle-favorite") { const note = state.notes.find((item) => item.id === action.dataset.noteId); if (note) { note.isFavorite = !note.isFavorite; note.updatedAt = nowISO(); saveState(); renderApp(); } }
  if (kind === "delete-note") deleteNote(action.dataset.noteId);
  if (kind === "accept-suggestion" || kind === "dismiss-suggestion") { const suggestion = state.tagSuggestions.find((item) => item.id === action.dataset.suggestionId); if (suggestion) { suggestion.decision = kind === "accept-suggestion" ? "accepted" : "ignored"; if (kind === "accept-suggestion") { const note = state.notes.find((item) => item.id === suggestion.noteID); if (note) note.acceptedTags = unique([...(note.acceptedTags || []), ...suggestion.tags]); } saveState(); renderApp(); showToast(kind === "accept-suggestion" ? "Tags accepted." : "Suggestion dismissed."); } }
  if (kind === "library-mode") { state.library.mode = action.dataset.mode; renderApp(); }
  if (kind === "first-note-edit") { if (state.notes[0]) openEdit(state.notes[0].id); }
  if (kind === "toggle-source") toggleSource(action.dataset.sourceId);
  if (kind === "generate-conclusion") generateConclusion();
  if (kind === "accept-consent") { state.preferences.aiProcessingConsent = "accepted"; if (state.askSession) state.askSession.phase = "review"; saveState(); renderApp(); showToast("Selected-excerpt consent saved."); }
  if (kind === "decline-consent") { state.preferences.aiProcessingConsent = "declined"; if (state.askSession) state.askSession.phase = "review"; saveState(); renderApp(); showToast("AI processing remains disabled."); }
  if (kind === "back-to-evidence") { if (state.askSession) state.askSession.phase = "review"; renderApp(); }
  if (kind === "clear-ask") { state.askSession = null; renderApp(); }
  if (kind === "save-plan") createPlan();
  if (kind === "copy-conclusion") copyText(conclusionText(), "Conclusion copied.");
  if (kind === "select-plan") { state.selectedPlanId = action.dataset.planId; renderApp(); }
  if (kind === "delete-plan") { if (window.confirm("Delete this plan?")) { state.plans = state.plans.filter((plan) => plan.id !== action.dataset.planId); state.selectedPlanId = state.plans[0]?.id || null; saveState(); renderApp(); showToast("Plan deleted."); } }
  if (kind === "toggle-checklist") { const plan = state.plans.find((item) => item.id === action.dataset.planId); const item = plan?.checklist?.[Number(action.dataset.index)]; if (item) { item.isComplete = action.checked; plan.updatedAt = nowISO(); saveState(); renderApp(); } }
  if (kind === "share-plan") { const plan = state.plans.find((item) => item.id === action.dataset.planId); if (!plan) return; const text = planShareText(plan); if (navigator.share) navigator.share({ title: plan.title, text }).catch(() => {}); else copyText(text, "Plan preview copied."); }
  if (kind === "clear-history") { state.history = []; saveState(); showToast("Query history cleared."); }
  if (kind === "export-archive") exportArchive();
  if (kind === "import-archive") importFile.click();
  if (kind === "delete-all") { if (window.confirm("Delete all web notes, plans, tags, and history?")) { localStorage.removeItem(STORAGE_KEY); state = defaultState(); renderApp(); showToast("All web data deleted."); } }
});

appView.addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.target; const formData = new FormData(form);
  if (form.dataset.form === "capture") createNote(formData);
  if (form.dataset.form === "edit-note") updateNote(formData);
  if (form.dataset.form === "ask") doAsk(formData);
  if (form.dataset.form === "plan") { const plan = state.plans.find((item) => item.id === formData.get("planId")); if (plan) { plan.title = String(formData.get("title") || "Untitled plan").trim(); plan.conclusion = String(formData.get("conclusion") || "").trim(); plan.updatedAt = nowISO(); saveState(); renderApp(); showToast("Plan updated."); } }
});

appView.addEventListener("input", (event) => {
  if (event.target.matches("[data-character-count]") || event.target.matches("textarea[name=body]")) { const counter = event.target.closest("form")?.querySelector("[data-character-count]"); if (counter) counter.textContent = `${event.target.value.length} characters`; }
  if (event.target.id === "library-search") { state.library.query = event.target.value; updateLibraryResults(); }
});

appView.addEventListener("change", (event) => {
  const filter = event.target.closest("[data-filter-prefix]");
  if (filter) { const prefix = filter.dataset.filterPrefix; state[prefix].filters[filter.dataset.filter] = filter.type === "checkbox" ? filter.checked : filter.value; updateLibraryResults(); return; }
  const setting = event.target.closest("[data-setting]");
  if (setting) { if (setting.dataset.setting === "consent") state.preferences.aiProcessingConsent = setting.value; if (setting.dataset.setting === "model") state.preferences.model = setting.value; if (setting.dataset.setting === "history") state.preferences.keepLocalHistory = setting.checked; saveState(); showToast("Setting saved."); }
});

importFile.addEventListener("change", () => { if (importFile.files?.[0]) importArchive(importFile.files[0]); importFile.value = ""; });

renderApp();
