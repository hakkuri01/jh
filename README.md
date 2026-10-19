<p align="center">
  <img src="assets/jh.png" alt="Jekyll // Hyde" width="300">
</p>

<p align="center">
<img src="https://img.shields.io/badge/Crystal-black.svg?style=plastic&logo=crystal&logoColor=white">
<img src="https://img.shields.io/badge/v0.1.0-B060E8.svg?style=plastic&logo=git&logoColor=white">
<img src="https://img.shields.io/badge/Bug%20Bounty-F03048.svg?style=plastic&logo=owasp&logoColor=white">
</p>

Jekyll // Hyde is a single-binary interactive TUI web fuzzer with two personalities in one shell. Two tools defined the two ways people fuzz the web, and jh gives each one a mode: Hyde takes after [feroxbuster](https://github.com/epi052/feroxbuster), the broad, recursive, auto-tuning discovery you reach for to open a target, and Jekyll takes after [ffuf](https://github.com/ffuf/ffuf), the precise, templated `FUZZ` fuzzing you reach for once you know what you're looking for. jh marries those two personalities into one cohesive, keystroke-switchable TUI fuzzer, so a single session carries a target from broad discovery into focused follow-on work without switching back and forth between two separate tools.

> [!CAUTION]
>
> *Jekyll // Hyde is intended for authorized security testing and research. Always ensure you have explicit permission to scan targets you do not own.*

---

## Architecture

- **One binary, zero runtime dependencies.** Crystal 1.21.1, standard library only; the Elm-architecture TUI runtime is built in-house.
- **Interactive by design.** The binary always launches the full-screen TUI; there is no headless mode yet (it is on the [Roadmap](#roadmap)). With no arguments it opens the composer; given a full command it launches straight onto the running scan dashboard (the power-user override), skipping the opener and the form.
- **Hostile-target safe.** Every response is sanitized before it reaches the terminal, bodies are size-capped, redirect and link targets are validated before they are followed, and supplied headers and cookies are never written to results.

### Modes

Opens in Hyde and switches to Jekyll (and back) with `Tab`; the transition is a deliberate visual shift, and the active mode colors the whole shell.

- **Hyde** (default): broad, deep content discovery. Point it at a target and it maps everything it can find, recursing into the directories it discovers, mining links from response bodies and `robots.txt`, calibrating out wildcard and soft-404 noise (an exact size/word/line fingerprint plus a SimHash near-duplicate fallback), and optionally auto-tuning concurrency when a host starts pushing back.
- **Jekyll**: precise, templated fuzzing. A `FUZZ` keyword marks the injection point in the URL, a header (`-H`), a cookie (`-b`), or the method (`-X`), substituted per request. Explicit status, size, word, line, regex, and time matchers and filters (combined with and/or), clusterbomb and pitchfork multi-wordlist input, and opt-in auto-calibration keep the scan tightly scoped.

Everything is interactive: you compose the scan (URL, flags, switches) in the shell, watch it run live, and the composition is itself the run command, shown live and copyable at the foot of the form.

---

## Install

### Nix (primary)

```bash
nix run github:hakkuri01/jh              # run it without installing
nix profile install github:hakkuri01/jh  # install it
```

In a clone, the flake's dev shell has Crystal, `just`, and the linked libraries:

```bash
nix develop
just verify   # format, lint, specs, reachability, release build
```

### From source (without Nix)

Requires [mise](https://mise.jdx.dev) and a C toolchain:

```bash
mise trust && mise install   # Crystal 1.21.1 + just
just setup                   # fetch and build the one dev dependency (Ameba)
just verify                  # the gate
./bin/jh                     # run
```

---

## Usage

`jh` with no arguments opens the composer. Give it a full command and it launches straight onto the running scan dashboard, skipping the opener and the form, so a one-off scan is one line. There is no headless runner yet: jh is always the TUI today, so a command needs an interactive terminal and must name a mode (`--hyde` or `--jekyll`), since it runs at once. Multi-character flags are double-dashed (Crystal's option style); single letters stay short; the interactive `h` page lists them all.

```bash
jh [--hyde | --jekyll] -u URL -w WORDLIST [options]
```

Common to both modes:

| Flag | Meaning |
| --- | --- |
| `-u URL` | target URL (`FUZZ` marks the Jekyll injection point) |
| `-w FILE` | wordlist path (repeatable; `FILE:KEYWORD` binds a Jekyll input keyword) |
| `-e LIST` | extensions to append to words, e.g. `php,html` |
| `-t N` | concurrent requests (default 40) |
| `-X METHOD` | HTTP request method (default GET) |
| `-H "Name: Value"` | request header, repeatable (`FUZZ`-able in Jekyll) |
| `-b COOKIE` | Cookie header value (`FUZZ`-able in Jekyll) |
| `-k` | skip TLS certificate verification |
| `-o FILE`, `--format json\|csv` | write results to a file when the scan finishes |
| `-h` | show this help |

Hyde (recursive discovery):

| Flag | Meaning |
| --- | --- |
| `-d N` | max recursion depth (default 4) |
| `--no-recursion` | scan only the target, no descent |
| `--auto-tune` | back off concurrency under 429 / 403 floods |

Jekyll (templated fuzzing):

| Flag | Meaning |
| --- | --- |
| `FUZZ` | injection keyword, required somewhere in the request (URL, a header, a cookie, or the method) |
| `--mc --fc` | match / filter by status code |
| `--ms --fs` | match / filter by response size |
| `--mw --fw` | match / filter by word count |
| `--ml --fl` | match / filter by line count |
| `--mr --fr` | match / filter by regex (headers + body) |
| `--mt --ft` | match / filter by response time |
| `--mmode --fmode` | how matchers / filters combine: `and` or `or` (default `or`) |
| `--mode` | multi-wordlist input: `clusterbomb` or `pitchfork` |
| `--ac` | auto-calibrate wildcard filters before the run |

### Examples

```bash
# Recursive discovery (Hyde)
jh --hyde -u https://example.com -w wordlist.txt

# Deeper recursion, more concurrency, with auto-tune
jh --hyde -u https://example.com -w wordlist.txt -d 6 -t 80 --auto-tune

# Templated fuzzing (Jekyll): match 200/301/403, drop a 1234-byte wildcard
jh --jekyll -u https://example.com/FUZZ -w wordlist.txt --mc 200,301,403 --fs 1234

# Two wordlists in a clusterbomb, regex matcher, CSV export
jh --jekyll -u https://example.com/FUZZ/FUZ2Z -w words.txt:FUZZ -w vals.txt:FUZ2Z --mode clusterbomb --mr admin -o out.csv --format csv
```

### Interactive Dashboard

`jh` with no arguments launches the full-screen app and walks through the steps below. A full command skips straight to step 3, the running dashboard.

1. An opening screen plays the boot sequence. Press any key to continue.
2. A vim-style command form collects the target, the wordlist, and the option switches, building a live `jh …` command at the foot.
3. Enter runs the scan once the mandatory fields are set (target and wordlist, plus a `FUZZ` keyword in Jekyll). Results stream newest-first into the dashboard as they land.
4. When it finishes, `q` steps back to the form to compose and run another; from the form, `q` quits.

| Mode | Key | Action |
| --- | --- | --- |
| Form (NORMAL) | `j`/`k`, `↑`/`↓` | Move between fields |
| Form (NORMAL) | `i` | Edit the focused field |
| Form (NORMAL) | `tab` | Switch the mode |
| Form (NORMAL) | `h` | Open the flag and key reference (`q` or `h` closes it) |
| Form (NORMAL) | `enter` | Run the scan |
| Form (NORMAL) | `q` | Quit |
| Form (INSERT) | type, `←`/`→`, `home`/`end` | Edit; `enter` runs, `esc` returns to NORMAL |
| Dashboard | `j`/`k`, `pgup`/`pgdn`, `home`/`end` | Scroll the results |
| Dashboard | `p` | Pause / resume the scan |
| Dashboard | `q` | Stop the scan, back to the form |
| Anywhere | `ctrl+c` | Quit |

A bare drag selects and copies text, and the wheel scrolls; the app does not capture the mouse. `esc` never cancels a running scan or drops a view by reflex; `q` is the one that steps back. A full command needs a terminal to draw into: run outside one (a pipe or redirect) and it prints an error instead of opening, so run it in a terminal. A bare `jh` with no arguments on a pipe prints its banner and version instead.

---

## Output

Results are not written to disk by default. Pass `-o FILE` to write them, when the scan finishes, as JSON (the default) or CSV with `--format csv`. Supplied request headers and cookies are never written to an export.

---

## Roadmap

Default scans are complete in both modes. These are the opt-in paths jh will grow into next.

- **Mid-run scan control.** A scan already pauses, resumes, and cancels. Next is running several at once from the dashboard: add a target without stopping the others, cancel a single scan, add or remove a filter mid-run, and raise or lower the concurrency limit while a scan is live.
- **Explicit near-duplicate filtering.** Hyde already drops soft-404 near-duplicates by default. The next step is an explicit switch that filters every response against a reference page you supply, for targets whose noise does not look like a 404.
- **Custom and per-host calibration.** Jekyll runs one built-in calibration strategy today. Next: supply your own calibration probes and strategy, and calibrate each host separately once a single run can target more than one origin.
- **Request-body fuzzing.** Jekyll fuzzes `FUZZ` in the URL, headers, cookies, and method today. The remaining ffuf-parity gap is a `-d` request body (and `FUZZ` within it), for fuzzing form and JSON payloads on POST/PUT.
- **Interactive wordlist finder.** In the composer, pressing `/` on a filled wordlist field opens a finder window that loads the list and filters it live by substring, so you can confirm a list holds what you expect before launching; `q` returns to the form. Read-only verification, built on the existing wordlist search.
- **Linux terminal sizing.** Today jh reads the terminal size through a Darwin `ioctl`; on the Linux targets the flake builds it falls back to 80x24 and does not follow resizes. The fix is a Linux `TIOCGWINSZ` path (with a `$COLUMNS`/`$LINES` fallback) so the full-screen UI scales and reflows there as it does on macOS.
- **Reproducible Nix build.** The flake pins Crystal 1.21.1 but still carries a placeholder compiler-source hash and no committed `flake.lock`, so `nix build` needs the real hash wired in and the lock committed before the Nix install path is reproducible from a clean checkout.
- **Headless runs.** A `--headless` flag for the power user who wants the raw engine without the TUI. A full command already skips the opener and the form and lands on the live dashboard, so a quick `q` `q` is back at the shell for the next scan. Headless goes one step further: no full-screen app, no dashboard, and no terminal required. The scan runs and its results go straight to the export location (`-o FILE`, JSON or CSV per `--format`), or to stdout when no file is named, so they pipe into the next tool. Progress and errors stay on stderr so stdout is clean data, and the exit code reports how the run ended, so prepared command strings chain in scripts, CI, and automation workflows. As security research leans further on AI agent workflows, this is how jh drops into an agent's environment: the same engine and flag grammar as the TUI, borrowed as a plain command. Every response is still sanitized before it is written, and supplied headers and cookies still never reach an export.
- **HTTP/2.** jh speaks HTTP/1.1 today. Negotiating HTTP/2 over TLS is the modern fuzzing-tool standard, and a target that answers differently over HTTP/2 than over HTTP/1.1 is a parity gap: small enough to be a non-issue on the large majority of scans, but real. The plan, if we take it on, is transparent HTTP/2 in Hyde (negotiated when the target offers it, falling back to HTTP/1.1) and opt-in in Jekyll behind an `--http2` flag, default off, so precise fuzzing stays exactly as composed. It is substantial work, since Crystal's standard library has no HTTP/2 client: we would either lean on a maturing community shard such as [ysbaddaden/http2](https://github.com/ysbaddaden/http2) if it keeps progressing, or hand-roll our own as [Gori](https://github.com/hahwul/gori) does. Either way it is tabled until we choose to build it, or until the language ecosystem closes the gap first.
