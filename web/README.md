# NoteMap AI web companion

This is a separate, static browser version of NoteMap AI. It lives in `web/`
and does not modify the Swift/Xcode iOS project. The native app remains the
source of truth for iOS-only capabilities.

## Run locally

From the `web/` folder:

```bash
python3 -m http.server 4173
```

Then open <http://localhost:4173>.

## What is implemented

The browser version mirrors the mobile app’s portable workflows:

- Thirty varied test notes are included in the initial web dataset, covering
  multiple dates, themes, tags, places, favorites, coordinates, actions, and
  questions.
- Home quick capture with title, body, date, theme, place, coordinates, and tags.
- Local persistence in `localStorage`; notes can be edited, favorited, deleted, and exported.
- Suggested tags with accept and dismiss actions.
- Library search across note content and metadata, with tag/date/place/theme/favorite filters.
- List, card, and coordinate-map views for notes.
- Ask workflow with local retrieval, evidence selection, first-use consent, and a grounded demo conclusion.
- Plans with editable conclusions, checklists, source links, sharing/copying, and deletion.
- Settings for consent, model label, local history, JSON export/import, privacy, and reset.

## Important limitation

The current web version uses deterministic local conclusion generation so it is
safe to deploy immediately and does not expose an API key. It does not yet call
OpenAI. To add real AI generation, create a server-side `/api/conclusion`
endpoint (or a separate backend) that stores the provider key on the server and
accepts only the question plus the evidence excerpts selected by the user.
Never put an OpenAI key in `app.js` or any other browser file.

The iOS widget, share extension, system capture integration, iOS Keychain, and
native location permissions cannot be reproduced by a static website. The web
equivalents are paste/import, browser sharing, local browser storage, and
manual place/coordinate fields.

If the browser was opened before the 30-note dataset was added, export any
important web data first, then use **Settings → Delete all web data**. The
browser will reset to the 30 test notes.

## Deploy on Vercel

1. Push the `web/` folder to GitHub. From the repository root, stage only this
   folder if the iOS project has unrelated local changes:

   ```bash
   git add web
   git commit -m "Add NoteMap AI web companion"
   git push origin main
   ```

2. In Vercel, choose **Add New → Project**, then import the private
   `ylwhale/NoteMapAI` repository.
3. Set **Root Directory** to `web`.
4. Set **Framework Preset** to **Other**.
5. Leave **Build Command** empty and set **Output Directory** to `.`.
6. Deploy. Every later push to the selected branch will create a new
   deployment.

The included `vercel.json` keeps direct page navigation working.

## Deploy on Netlify

1. Push the repository changes to GitHub.
2. In Netlify, choose **Add new site → Import an existing project**, then
   select the GitHub repository.
3. Set **Base directory** to `web`.
4. Leave **Build command** empty and set **Publish directory** to `.`.
5. Deploy.

The included `netlify.toml` contains the same static-site settings and keeps
direct page navigation working.
