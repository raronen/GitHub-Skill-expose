---
name: expose
description: Publish one self-contained local .html file through a temporary public Cloudflare Quick Tunnel URL. Use when the user invokes /expose or asks to expose, share, or publish a local HTML file temporarily over the public internet.
---

# Expose

Expose exactly one self-contained local HTML file at a temporary public URL.

Invoke as:

```text
/expose <absolute-or-workspace-relative-path-to-file.html>
```

## Required behavior

1. Resolve the requested path to an existing `.html` file. If no path or attachment
   is identifiable, ask the user for the file.
2. Explain before proceeding only when the file appears to contain credentials,
   tokens, private customer data, or other sensitive material. Never expose such
   content without explicit confirmation.
3. Run:

   ```powershell
   & "$env:USERPROFILE\.copilot\skills\expose\scripts\Start-Expose.ps1" `
     -HtmlPath "<absolute-html-path>"
   ```

4. Require a structured result with `Ready` equal to `true`.
5. Return the `PublicUrl` prominently and state that the URL remains available only
   while the local `python` and `cloudflared` processes are running.
6. Mention the stop command:

   ```text
   /expose stop
   ```

Do not claim success from log text alone. The start script verifies both the local
server and the public URL before returning.

## Isolation and safety

- The script copies only the selected file to an isolated staging directory as
  `index.html`; it never serves the source directory or sibling files.
- The page must be self-contained. Relative images, scripts, stylesheets, and other
  local assets are not copied and therefore will not load.
- The public URL has no authentication and is accessible to anyone who has it.
- Cloudflare Quick Tunnel URLs are temporary and may change on every start.
- Do not upload the file to a permanent host or third-party storage service.
- Never modify the source HTML.

## Stop

For `/expose stop`, run:

```powershell
& "$env:USERPROFILE\.copilot\skills\expose\scripts\Stop-Expose.ps1"
```

Require `Stopped` equal to `true`, then report that the public URL is offline.

