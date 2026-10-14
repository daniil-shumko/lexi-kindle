# Changelog

## 1.0.0

First public release.

- **Ask AI in KOReader:** in the dictionary popup and the selection menu. You get the word's meaning in context, a note and an example, and translations, from Claude or OpenAI.
- **Ask AI in the Kindle's own reader:** a button next to Amazon's dictionary popup. Turn it on from the *Lexi: Ask AI on/off* item in your library (a scriptlet). It shows in a window of Lexi's own and works on firmware 5.18, in both of its readers: the older one, and the newer one Amazon's own books open in.
- **Prompts:**
  - five built-in ones: Explain & translate, Explain like I'm 5, Translation only, Deep dive and Grammar;
  - your own prompts, with placeholders such as `{word}`, `{context}` and `{translate_to}`;
  - **Ask again as…** re-asks a word with another prompt, in both readers.
- **Earlier answers:** a word you already asked about shows its earlier answer at once, with no new request, in both readers. **Ask AI again** gets a fresh one.
- **Set up from your phone:** scan a QR code, paste your API key, pick the model, effort, languages and prompt, and write your own prompts.
- **Model and effort pickers:**
  - Claude Opus 5.5, Sonnet 5.5, Haiku 5.5;
  - GPT-6.1 Sol, GPT-6 Astra, GPT-6 Luna;
  - or any model ID.
- **Saved words** with their sentence, book and answer, and optional sync to a server of your own ([the contract](docs/how-it-works.md#your-own-backend)).
- **HTTPS certificate checking:** the chain against KOReader's CA bundle, and the provider's host name.
