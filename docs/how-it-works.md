# How Lexi works

Lexi has two front ends that share one core:

```
 KOReader ─────────── lexi.koplugin/main.lua ───────┐
   dictionary popup / selection menu → "Ask AI"     │
                                                    ├──▶ lexi_presets    built-in and custom prompts
 Kindle's own reader ─ lexi.koplugin/native/ ───────┤    lexi_prompt     builds the prompt
   dictionary popup → "Ask AI · word" button        │    lexi_providers  Claude / OpenAI / backend requests
   (lexid.lua daemon + Lexi's own window)           │    lexi_client     HTTPS (certificate-checked)
                                                    │    lexi_format     answer → HTML with bold labels
 Phone setup ──────── lexi_setup.lua ───────────────┘    lexi_cache      earlier answers
                                                         lexi_store      saved words
                                                         lexi_config     settings
```

Everything is Lua running on **KOReader's own LuaJIT**. KOReader already ships LuaSocket, LuaSec, SQLite, rapidjson and a QR encoder, and the Kindle firmware ships GTK and WebKit, so Lexi has no binaries of its own and needs no cross-compiling.

## The prompt

For each lookup Lexi sends:

- the selected word and about 40 words on each side, with the word marked `⟦like this⟧`;
- the book's title and author;
- the book's language: the explanation is written in it, and translations go to every other language in your list.

With the default prompt, *Explain & translate*, the model answers in a fixed, compact layout:

```
acknowledged → acknowledge (verb; here past participle used adjectivally)
Meaning: Accepted or admitted as true. "Universally acknowledged" means everyone agrees it is true.
Note: The famous opening line is ironic…
Example: She is widely acknowledged as the best pianist in the town.
RU: признанная, общепризнанная
ES: reconocida, admitida
```

`lexi_format.lua` turns this into HTML: a bold headword, bold labels, and a rule above the translations. KOReader renders it with the same engine as its dictionary popup, and the Kindle reader with WebKit.

### Prompts

`lexi_presets.lua` holds the prompts. Each built-in one (*Explain & translate*, *Explain like I'm 5*, *Translation only*, *Deep dive*, *Grammar*) is a system prompt with its own rules and length limit, plus a layout of labelled lines, so every answer renders the same way. The translation lines and the book's language work the same in all of them.

A custom prompt is a template the user writes, such as `Explain {word} in {context} simply`. Lexi fills the placeholders in a single pass, so a value that happens to contain `{word}` is never expanded again, and unknown placeholders stay as written. The result is sent as the user message, under a short system prompt that only asks for plain text, which suits e-ink. Its answer is shown as plain paragraphs, without the bold headword.

Settings keep the active prompt's id (`prompt`) and the custom prompts (`custom_prompts`, a list of `{ id, name, template }`). If a saved id no longer exists, for example because that custom prompt was deleted, Lexi falls back to *Explain & translate*.

### Earlier answers

Every answer is stored in `koreader/settings/lexi_answers.lua`, which both front ends read, so a word is paid for once. Before building a request, `lexi_cache.lua` looks up a key made of:

- the word, with spaces squashed and letters lowercased (ASCII, Latin-1 and Cyrillic, so a capitalized word at the start of a sentence still matches);
- the prompt's id, plus a hash of the template for a custom prompt, so editing it asks again;
- the book's language and the translation languages, which change what the answer contains.

The passage is left out on purpose: the second lookup of a word, in another sentence, is the one worth saving. A hit is shown at once, even offline or without an API key, under an *Earlier answer · date* line and with an **Ask AI again** button. That button sends the request anyway, and the new answer replaces the stored one. Only the newest 500 answers are kept, about half a megabyte.

## In KOReader

A standard KOReader plugin:

- `ReaderHighlight:addToHighlightDialog` adds **Ask AI** to the selection menu.
- `ReaderDictionary:addToDictButtons` (newer KOReader) or the `DictButtonsReady` event (older) adds it to the dictionary popup.
- The request runs in a forked subprocess (`Trapper:dismissableRunInSubprocess`), so the UI stays responsive and a tap cancels it.
- The answer shows in a `ScrollHtmlWidget` popup at your dictionary font size. **Ask again as…** re-runs the same query with another prompt, without changing the default.
- An [earlier answer](#earlier-answers) skips the request and the subprocess. It shows in the same popup, with **Ask AI again** on top of the buttons.

## In the Kindle's own reader

Amazon's reader offers no API for this, so this part took some reverse engineering, on a Kindle Paperwhite 12th gen with firmware 5.17 and then 5.18.6.

### 1. Finding a signal when a word is looked up

While three words were looked up, a capture script (`scripts/native-capture.sh`) recorded every **LIPC** event (the Kindle's internal message bus), all system **D-Bus** traffic, the **system log** and every **file** written.

- No LIPC or D-Bus event carries the word. The dictionary popup is a Java dialog inside the framework's VM (`cvm`).
- The system log does show the popup opening and closing:

  ```
  cvm[5127]: I KindleFrameFactory:WindowAdded:title=…_A_SelectionDialogImpl_…:
  cvm[5127]: I KindleFrameFactory:WindowRemoved:title=…_A_SelectionDialogImpl_…:
  ```

- In the same second, the **Vocabulary Builder** database (`/mnt/us/system/vocabulary/vocab.db`) gets a new row. It holds the word, its stem and language, the **whole sentence** it came from (`LOOKUPS.usage`) and the book (`BOOK_INFO`).

So: the log line says *when*, and the database says *what*. That is everything the prompt needs. Both still hold on firmware 5.18.6.

**Two readers on firmware 5.18.** Firmware 5.18 opens some books, such as ones bought from Amazon, in a newer React Native reader (`KPPMainApp`). It has a different popup and logs no `SelectionDialogImpl` window. Its popup shows up in the log as:

```
KPPMainApp: [5392] [CABSelectionListener:INFO] selectionStabilized, selectionMode=1, willDisplayCAB=1
KPPMainApp: [5392] [KUXSelectionListener:INFO] selectionFinalized called
```

The first line appears when the popup opens and the second when the selection ends. Its lookups go to the same Vocabulary Builder database, so the rest works the same.

The Java reader logs every popup line twice, and the second copy sometimes lands seconds later. The bridge folds the repeats (`Native.popupWatch`): another "opened" while the popup is open only extends the wait for its lookup, and only the first "closed" counts. It looks for the lookup between log lines and never blocks on them. If it blocked, it would fall behind your taps, and a late "closed" could hide the next word's button.

> **If the newer reader's dictionary stops working**, check `lipc-get-prop com.lab126.system usid`. That reader needs the device serial number to open Amazon's dictionary. On one Kindle, `lipc-daemon` deadlocked a helper it started to read the serial, after a library-indexer crash. From then on, every request waited 10–20 s and failed: books opened slowly, and the reader showed *No dictionary selected*. Lexi isn't involved. Ending the stuck `lipc-daemon` child, or restarting the Kindle, fixes it.

> The capture also showed that `IdentityService` broadcasts the Amazon access token over LIPC. The capture script redacts `Atza|…` tokens before saving anything.

### 2. Showing something over the reader

Options considered:

| Approach | Problem |
|---|---|
| Draw with FBInk | The FBInk bundled with common jailbreak tools predates this panel: it writes pixels but can't refresh the screen. And the reader would redraw over it. |
| Pause the framework, as KOReader does (`SIGSTOP` the window manager) | Heavy, and it freezes the reader you're using. |
| The firmware's own dialog layer, "pillow" | Worked up to firmware 5.17 (see below). Firmware 5.18 replaced it. |
| **A window of Lexi's own, with the firmware's GTK and WebKit** | ✅ Handles touch, stays above the reader, and the screen refreshes like any other window. |

**Up to firmware 5.17**, Lexi used pillow, the WebKit-based layer that drew the Kindle's system dialogs. Its `customDialog` LIPC property loaded `/usr/share/webkit-1.0/pillow/<name>.html`, and a relative name reached a page on the user partition. **Firmware 5.18** rewrote pillow as a React Native app (`/app/KPPPillow`) that only opens Amazon's own dialogs. Anything else is logged as `Unable to determine the requested dialog type`, and the HTML files are gone. The library items still ran, but all you saw was the screen flashing.

The firmware still runs X11 with the awesome window manager, and its status bar is a GTK2 window. GTK2 and WebKitGTK 1.0 are still in `/usr/lib`. So **`native/ui.lua`** opens its own window, calling those libraries through LuaJIT's FFI:

- It is a borderless `GTK_WINDOW_POPUP` (override-redirect) that never takes the focus, so the window manager leaves it where the page puts it: above the reader, without closing the dictionary popup.
- It shows Lexi's existing pages (`native/*.html`) in a `WebKitWebView`. It opens and shows a page in about 0.2 s.
- `native/bridge.js` gives the pages the same small API pillow had (`nativeBridge.setWindowSize`, `setWindowPosition`, `showMe`, `dismissMe`, `sendLipcEvent`, `registerClientParamsCallback`). Each call becomes a `console.log("lexi:<op> …")`, which `ui.lua` receives through WebKit's `console-message` signal.
- Parameters go in as JSON lines on `ui.lua`'s standard input and are delivered with `execute_script("__lexiParams(…)")`. Taps come out on its standard output as `lexiAsk "<id>"`.
- KOReader's LuaJIT looks in `koreader/libs` first, where KOReader keeps its own builds of some libraries (its SQLite lacks `sqlite3_open16`, which WebKit needs). `ui.lua` loads the firmware's copies by full path before GTK, so every later lookup finds those.

No file on the read-only system partition is touched.

### 3. The bridge

`native/lexid.lua` runs headless on KOReader's LuaJIT (KOReader's device module is stubbed out, so it never touches the screen). `native/lexi.sh start` launches it and feeds one FIFO with two streams: the readers' popup lines from `tail -F /var/log/messages`, and the taps that Lexi's window writes out. lexid starts that window (`ui.lua dialog`) once and keeps it, writing each new state to it as a JSON line.

You turn it on from the Kindle library. The Universal Hotfix lets the library index `.sh` files in `documents/` as items ([scriptlets](https://kindlemodding.org/kindle-dev/scriptlets.html)), so Lexi ships two, *Lexi: Ask AI on/off* and *Lexi: Set up from phone*. They call `native/lexi.sh`; the launcher may run them as the `framework` user, so they go through the jailbreak's `su`. A `# DontUseFBInk` header stops the launcher from clearing the screen to show their output. Instead they report back in a small self-closing window (`ui.lua notice`).

1. *Popup opened* (log line, from either reader) → for up to 5 seconds, check `vocab.db` every 250 ms for a lookup newer than both the last one and the popup → show the window in "offer" mode: a small **Ask AI · word** button, with the prompt's name if it isn't the default.
2. *Popup closed* → the window hides if it is still only a button.
3. **`lexiAsk`** → build the prompt from the saved sentence → show the [earlier answer](#earlier-answers) if the word has one, else call the provider and store the answer → hand the formatted answer to the window.
4. **`lexiAskAs "<id> <prompt>"`** → the same with another prompt. Answers are kept per prompt, so going back to one doesn't ask again.
5. **`lexiAskAgain "<id> <prompt>"`** → from **Ask AI again** under an earlier answer: call the provider anyway, and replace the stored answer.
6. **`lexiSave`** → add the word, with the prompt that answered it, to the same list KOReader uses (`koreader/settings/lexi_words.lua`), and sync it if a backend is configured.

Updates that may arrive after you closed the window, such as an answer to a closed "Asking…", carry an `ifOpen` flag, and the page ignores them.

## Phone setup

`lexi_setup.lua` serves a small form on the Kindle's Wi-Fi address, port 8642 or the next free one, and opens that port in the Kindle firewall while it runs. The Kindle shows a QR code of `http://<kindle-ip>:8642/?c=<code>`:

- KOReader draws it with its `QRWidget`;
- from the library item, it appears in Lexi's window (`setup.html`), drawn on a `<canvas>`.

The form needs the 6-digit code, locks after 5 wrong codes, stops after one save or 10 minutes, and never sends a saved key back to the browser. Its **Prompt** card picks the active prompt and edits custom prompts. They are checked with the same rules as KOReader's editor before anything is saved.

## HTTPS

KOReader's LuaSec defaults to `verify = "none"`. Lexi passes `verify = "peer"` and KOReader's `data/ca-bundle.crt` with every request, so self-signed, expired and unknown-CA certificates are rejected. LuaSec doesn't check host names, so `lexi_tls.lua` does: after the handshake it checks that the certificate's names (subject alternative names, else the common name) cover the host Lexi connected to, with single-label wildcards only.

## Your own backend

A server of your own can receive the words you save, for a study app for example, and can also answer lookups. Set its address and a device token in KOReader → Tools → Lexi → **My backend**, or as `backend_url` and `backend_token` in `config.lua`. The phone setup page doesn't set them.

Every request is a JSON `POST` with `Authorization: Bearer <device token>`, sent with the same certificate checks as the AI providers (see [HTTPS](#https)). `{backend_url}` may end with a slash or not.

### Saved words: `POST {backend_url}/v1/words`

Once a URL and token are set, every **Save word** uploads the word straight away, in both readers and whichever AI answered it. Words saved while the upload fails, or offline, wait on the Kindle and go with the next save or with **Sync now** (KOReader → Lexi → *Saved words*). Each word is its own request, oldest first, and syncing stops at the first failure so that words arrive in order. Any 2xx response counts as stored.

```json
{
  "id": "1791887150-3fa2",
  "word": "ephemeral",
  "context": { "prev": "The pleasures of the desert were", "next": "and gone with the morning wind." },
  "book": { "title": "Dune", "authors": "Frank Herbert", "language": "en" },
  "answer": "ephemeral → ephemeral (adjective)\nMeaning: Lasting a very short time.\n…",
  "provider": "claude",
  "model": "claude-opus-5-5",
  "preset": "explain",
  "created_at": 1791887150,
  "source": "kindle"
}
```

| Field | |
|---|---|
| `id` | Stable for each saved word (`<created_at>-<4 hex digits>`). A word can arrive twice, for example when the response to its first upload was lost, so store it once per `id`. |
| `word` | The selection as it appears in the book. |
| `context` | The text before and after it: about 40 words each way in KOReader, the rest of the sentence the Kindle saved in its own reader. |
| `book` | `language` is a two-letter code such as `en`, or absent when the book doesn't say. |
| `answer` | The answer as shown: the labelled layout above, or plain text for a custom prompt. |
| `provider`, `model` | Who answered: `claude`, `openai` or `backend`, and the model ID. |
| `preset` | The prompt's id: `explain`, `eli5`, `translate`, `deep`, `grammar` or `customN`. |
| `created_at` | When it was saved, in Unix seconds. |
| `source` | Where it was saved: `koreader`, or `kindle` for the Kindle's own reader. |

Fields with no value are left out.

### Answers: `POST {backend_url}/v1/explain`

With **My backend** chosen as the AI provider, lookups go to your server instead of Claude or OpenAI, which keeps provider keys off the Kindle. Lexi still shows [earlier answers](#earlier-answers) without asking.

```json
{
  "word": "ephemeral",
  "context": { "prev": "…", "next": "…" },
  "book": { "title": "…", "authors": "…", "language": "en-US" },
  "explain_language": "en",
  "translate_to": ["ru", "es"],
  "preset": "explain",
  "prompt": { "system": "…", "user": "…" }
}
```

- `book.language` is what the book reports; `explain_language` is that as a two-letter code (absent when unknown); `translate_to` is your languages without the book's (absent when empty).
- `prompt` is only sent for a custom prompt (`preset` is `customN`), with its placeholders filled in. For a built-in prompt, your server writes the prompt itself.
- Reply with `{ "text": "…" }`, in the labelled layout above for a built-in prompt (that is what Lexi formats) or plain text for a custom one.
- On failure, reply with a non-2xx status and `{ "error": { "message": "…" } }` (or `{ "error": "…" }`, or `{ "message": "…" }`). Lexi shows *HTTP &lt;status&gt;: &lt;message&gt;*.

## Limits

- The Kindle-reader bridge must be turned on from the library after each reboot. Autostart would need a job on the system partition.
- It reacts to dictionary lookups, so phrase selections aren't covered there yet.
- It relies on firmware details (log format, the GTK and WebKit libraries, the Vocabulary Builder schema) observed on firmware 5.17 and 5.18.6. Other versions may differ.
