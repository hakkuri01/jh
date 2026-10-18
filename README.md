<p align="center">
  <img src="assets/jh.png" alt="Jekyll // Hyde" width="100%">
</p>

<p align="center">
<img src="https://img.shields.io/badge/Crystal-black.svg?style=plastic&logo=crystal&logoColor=red">
<img src="https://img.shields.io/badge/v0.1.0-black.svg?style=plastic&logo=git&logoColor=red">
<img src="https://img.shields.io/badge/Bug%20Bounty-black.svg?style=plastic&logo=owasp&logoColor=red">
</p>

Jekyll // Hyde is a single-binary interactive TUI web fuzzer with two personalities in one shell. Two tools defined the two ways people fuzz the web, and jh gives each one a mode: Hyde takes after [feroxbuster](https://github.com/epi052/feroxbuster), the broad, recursive, auto-tuning discovery you reach for to open a target, and Jekyll takes after [ffuf](https://github.com/ffuf/ffuf), the precise, templated `FUZZ` fuzzing you reach for once you know what you're looking for. jh marries those two personalities into one cohesive, keystroke-switchable TUI fuzzer, so a single session carries a target from broad discovery into focused follow-on work without switching back and forth between two separate tools.

> [!CAUTION]
>
> *Jekyll // Hyde is intended for authorized security testing and research. Always ensure you have explicit permission to scan targets you do not own.*

---

## Architecture

- **One binary, zero runtime dependencies.** Crystal 1.21.1, standard library only; the Elm-architecture TUI runtime is built in-house.
- **Interactive by design.** The binary launches into the full-screen TUI. A one-shot CLI (`jh` with arguments) runs a single scan and exits, for scripting and piping.
- **Hostile-target safe.** Every response is sanitized before it reaches the terminal, bodies are size-capped, redirect and link targets are validated before they are followed, and supplied headers and cookies are never written to results.

### Modes

Opens in Hyde and switches to Jekyll (and back) with `Tab`; the transition is a deliberate visual shift, and the active mode colors the whole shell.

- **Hyde** (default): broad, deep content discovery. Point it at a target and it maps everything it can find, recursing into the directories it discovers, mining links from response bodies and `robots.txt`, calibrating out wildcard and soft-404 noise (an exact size/word/line fingerprint plus a SimHash near-duplicate fallback), and optionally auto-tuning concurrency when a host starts pushing back.
- **Jekyll**: precise, templated fuzzing. A `FUZZ` keyword marks the injection point in any part of the request. Explicit status, size, word, line, regex, and time matchers and filters (combined with and/or), clusterbomb and pitchfork multi-wordlist input, and opt-in auto-calibration keep the scan tightly scoped.

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

`jh` launches the interactive shell. With arguments, it runs a single scan and exits:

```bash
usage: jh [--hyde|--jekyll] -u URL -w WORDLIST [options]
    --hyde                      recursive discovery (default)
    --jekyll                    templated FUZZ fuzzing
    -u URL, --url=URL           target URL (FUZZ marks the Jekyll injection point)
    -w FILE, --wordlist=FILE    wordlist path
    -t N, --threads=N           concurrent requests (default 40)
    -d N, --depth=N             max recursion depth, Hyde (default 4)
    --match=CODES               match status codes, Jekyll (e.g. 200,301,403)
    --filter=CODES              filter status codes, Jekyll
    --calibrate                 autocalibrate wildcard filters, Jekyll
    -o FILE, --output=FILE      write results to FILE
    --format=FMT                export format: json or csv (default json)
    -h, --help                  show this help
```

### Examples

```bash
# Recursive discovery (Hyde, the default)
jh -u https://example.com -w wordlist.txt

# Deeper recursion with more concurrency
jh --hyde -u https://example.com -w wordlist.txt -d 6 -t 80

# Templated fuzzing (Jekyll): FUZZ marks the injection point
jh --jekyll -u https://example.com/FUZZ -w wordlist.txt --match 200,301,403

# Jekyll with autocalibration and a CSV export
jh --jekyll -u https://example.com/FUZZ -w wordlist.txt --calibrate -o results.csv --format csv
```

### Interactive Dashboard

`jh` (optionally with scan flags to prefill the form) launches the full-screen app.

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
| Dashboard | `j`/`k`, `pgup`/`pgdn`, `g`/`G` | Scroll the results |
| Dashboard | `p` | Pause / resume the scan |
| Dashboard | `esc` | Cancel the scan |
| Dashboard | `q` | Back to the form |
| Anywhere | `ctrl+c` | Quit |

A bare drag selects and copies text, and the wheel scrolls; the app does not capture the mouse. A piped or redirected run prints the one-shot line output instead of opening the app.

---

## Output

Results are not written to disk by default. Pass `-o FILE` to export them as JSON (the default) or CSV with `--format csv`. Supplied request headers and cookies are never written to an export.

---

## Roadmap

Default scans are complete in both modes. These are the opt-in paths jh will grow into next.

- **Mid-run scan control.** A scan already pauses, resumes, and cancels. Next is running several at once from the dashboard: add a target without stopping the others, cancel a single scan, add or remove a filter mid-run, and raise or lower the concurrency limit while a scan is live.
- **Explicit near-duplicate filtering.** Hyde already drops soft-404 near-duplicates by default. The next step is an explicit switch that filters every response against a reference page you supply, for targets whose noise does not look like a 404.
- **Custom and per-host calibration.** Jekyll runs one built-in calibration strategy today. Next: supply your own calibration probes and strategy, and calibrate each host separately once a single run can target more than one origin.
