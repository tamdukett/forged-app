# FORGED — Training System

A single-file web app (`index.html`) backed by Supabase. No build step.

## 1. Set up Supabase (one-time)
1. Create a project at https://supabase.com.
2. Open **SQL Editor** → paste and run `forged-schema.sql`.
3. Then paste and run `forged-seed.sql` (loads your exercise library + workout templates).
4. Go to **Project Settings → API** and copy the **Project URL** and **anon public key**.
5. Go to **Authentication → URL Configuration** and set **Site URL** (and add a **Redirect URL**) to your deployed site's address once you have it (step 3 below) — this is what makes signup confirmation emails link back to the right place.
6. Optional: **Authentication → Providers → Email** — turn off "Confirm email" while testing so new accounts don't need to click an email link.

## 2. Run it locally
Just open `index.html` in a browser, or click **Try demo mode**. To connect it to your real Supabase project, paste the URL + anon key into the setup screen the first time you load it (it's saved in the browser after that).

## 3. Deploy
Any static host works since this is a single HTML file. Easiest options:
- **GitHub Pages**: Settings → Pages → Deploy from branch → `main` / `/ (root)`.
- **Vercel** or **Netlify**: import this repo, no build command needed, output directory = `/`.

## Files
- `index.html` — the app
- `forged-schema.sql` — database tables + row-level security (run first)
- `forged-seed.sql` — exercise library + workout templates extracted from your PDFs (run second)
