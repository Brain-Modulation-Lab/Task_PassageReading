# Task_Reading

MATLAB stimulus presentation, audio recording, and neurophysiology trigger-logging repository for the continuous **Passage Reading** task (`task-reading`). Designed for preoperative (`preop`) and intraoperative (`intraop`) DBS speech/neurophysiology rigs without Psychtoolbox dependencies.

---

## Repository Structure

```text
Task_Reading/
├── START_READING.m                 # Top-level launcher & configuration file (single place to edit)
├── README.md                       # Documentation
├── scripts/
│   ├── task_reading.m              # Main task execution, text chunking, UI, and event logging
│   ├── set_paths_reading.m         # Hostname detection, MATLAB path setup, and BIDS path builder
│   ├── log_event.m                 # Shared BIDS events.tsv + Ripple xippmex TTL trigger logger
│   ├── record_audio.m              # Shared parallel-worker audio recorder (Focusrite / interface)
│   └── setup_audio_devices.m       # Shared host-specific audio input/output device configuration
└── stimuli/
    └── SLD_elicitation_passages.docx  # Input reading passage files (.docx, .rtf, .txt, etc.)
```

---

## Requirements

- **MATLAB** (Windows recommended for `.NET PresentationCore` low-latency key polling; includes standard MATLAB figure key-press fallback on macOS/Linux).
- **Audio Recording (Optional):** Audio Toolbox and Parallel Computing Toolbox (for background recording via `record_audio.m` on a parallel worker; automatically falls back to built-in `audiorecorder` if unavailable).
- **Neurophysiology Triggers (Optional):** Ripple `xippmex` MEX library on the MATLAB path (self-skipping when absent or when `cfg.DIGOUT = 0`).
- **Supported Passage Formats:**
  - **Native (no toolboxes required):** `.docx`, `.rtf`, `.txt`, `.md`, `.html`, `.htm`
  - **Extended (via Text Analytics Toolbox `extractFileText` or Windows Word COM):** `.pdf`, `.doc`, `.odt`

---

## Quick Start

1. **Add stimulus file:** Place your reading passage document inside `stimuli/` (e.g., `stimuli/SLD_elicitation_passages.docx`).
2. **Configure run parameters:** Open `START_READING.m` and set:
   - `cfg.SUBJECT` (default `'qqq'` for test runs, or subject ID such as `'DM1063'`)
   - `cfg.SESSION` (`'preop'` or `'intraop'`)
   - `cfg.stim_file` (filename inside `stimuli/`, or full path)
3. **Verify machine paths:** Confirm your machine's hostname (`char(java.net.InetAddress.getLocalHost.getHostName)`) is listed in `START_READING.m` and `scripts/set_paths_reading.m`.
4. **Launch:** Run `START_READING` in MATLAB.

---

## Configuration Parameters (`START_READING.m`)

All task settings are defined in the `cfg` struct at the top of `START_READING.m`:

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `cfg.SUBJECT` | `'qqq'` | BIDS subject identifier (`sub-<SUBJECT>`). |
| `cfg.SESSION` | `'intraop'` | Session label (`'preop'` sets `DIGOUT = 0`; `'intraop'` sets `DIGOUT = 1`). |
| `cfg.stim_file` | `'SLD_elicitation_passages.docx'` | Passage filename in `stimuli/` (or full file path). |
| `cfg.stim_font_size` | `80` | On-screen font size in points (reduce to `40`–`55` for dense multi-paragraph views). |
| `cfg.stim_font_name` | System default (`'Helvetica'`) | Font family used for display and pixel-width wrapping calculations. |
| `cfg.stim_font_weight` | `'bold'` | Font weight (`'normal'` or `'bold'`). |
| `cfg.text_color` | `[1 1 1]` | RGB `[0..1]` text color (default white). Triggers a modal warning dialog if too close to `background_color`. |
| `cfg.background_color` | `[0 0 0]` | RGB `[0..1]` screen background color (default black). |
| `cfg.screen_proportion` | `0.8` | Proportion `(0, 1]` of screen width and height used for text; horizontal and vertical margins scale proportionally to screen aspect ratio. |
| `cfg.max_sentences_per_paragraph` | `3` | Maximum sentences (delimited by periods) before inserting an extra paragraph break for readability. |
| `cfg.TASK` | `'reading'` | BIDS task label (`task-reading`). |

---

## Passage Processing & Screen Chunking

Before the intro screen appears, `task_reading.m` parses the input document and pre-computes exact screen pages:

1. **Paragraph Preservation & Subdivision:** Existing paragraph breaks are preserved. Any paragraph containing more than `cfg.max_sentences_per_paragraph` sentences (detected via periods, while protecting decimal numbers and common abbreviations like `Dr.`, `e.g.`, `U.S.`) is split into smaller paragraphs separated by blank lines.
2. **Aspect-Ratio Buffers & Pixel Wrapping:** Text is wrapped and paginated against the exact pixel dimensions of the usable screen area (`cfg.screen_proportion * [screen_width, screen_height]`), ensuring no text clips off-screen.
3. **Stimulus Table Export (`*_stim.tsv`):** All screen chunks are saved prior to task start with columns:
   - `chunk_id`: `1..N` sequential screen chunk index.
   - `stim`: Exact text displayed in that chunk, with paragraph breaks encoded as `\n\n` and line wraps as `\n`.

---

## Controls & Runtime Behavior

| State / Key | Action | Logging & Console Output |
| :--- | :--- | :--- |
| **Intro Screen** | Displays `Passage reading` followed by two line breaks and `Press any key to proceed`. | Logs `Intro_Onset` (`event_code = 1`). |
| **Any Key** (at Intro) | Advances from the intro screen to text chunk `1`. | Logs `Chunk_Change_start_chunk-1` (`event_code = 2`) and prints chunk preview to Command Window. |
| **Down Arrow (`↓`)** | Advances to the next screen chunk (`curr_chunk + 1`). | If moved: logs `Chunk_Change_down_chunk-<id>` (`event_code = 10`) and prints `[DOWN] Switched to text chunk X/N \| "first words ... last words"`.<br>If already at last chunk: prints boundary notice; **no event logged**. |
| **Up Arrow (`↑`)** | Returns to the previous screen chunk (`curr_chunk - 1`). | If moved: logs `Chunk_Change_up_chunk-<id>` (`event_code = 6`) and prints `[UP] Switched to text chunk X/N \| "first words ... last words"`.<br>If already at first chunk: prints boundary notice; **no event logged**. |
| **Escape (`Esc`)** | Opens a modal confirmation dialog (`End Task` vs. `Continue Reading`). | If `End Task`: logs `Task_End_Esc` (`event_code = 16`), closes files/windows, and stops audio recording.<br>If `Continue Reading`: returns focus to passage window without interrupting the run. |

---

## BIDS Outputs & Trigger Codes

Run IDs auto-increment (`run-01`, `run-02`, ...) based on existing `*_events.tsv` files in the session directory.

### Output Directory Layout

```text
<PATH_SOURCEDATA>/
└── sub-<SUBJECT>/
    └── ses-<SESSION>/
        ├── audio/
        │   └── sub-<SUBJECT>_ses-<SESSION>_task-reading_run-<XX>.wav
        └── task/
            ├── sub-<SUBJECT>_ses-<SESSION>_task-reading_run-<XX>_events.tsv
            ├── sub-<SUBJECT>_ses-<SESSION>_task-reading_run-<XX>_stim.tsv
            ├── sub-<SUBJECT>_ses-<SESSION>_task-reading_run-<XX>_log.txt
            └── sub-<SUBJECT>_ses-<SESSION>_task-reading_run-<XX>_script.m
```

### Digital Trigger Codes (`events.tsv`)

Events are written in standard 7-column BIDS format (`onset`, `duration`, `sample`, `trial_type`, `stim`, `value`, `event_code`). When `cfg.DIGOUT == 1`, Ripple digital outputs `1:4` carry the alternating `flip_sync` bit (`0` or `1`) and channel `5` carries `val + 32768 * flip_sync`:

| Event | Base Trigger (`val`) | `trial_type` | `event_code` Pattern |
| :--- | :---: | :--- | :--- |
| Intro screen onset | `1` (`TRIG_INTRO`) | `'control'` | `'Intro_Onset'` |
| First chunk onset (from intro) | `2` (`TRIG_VIS_STIM`) | `'reading'` | `'Chunk_Change_start_chunk-1'` |
| Move up to previous chunk | `6` (`TRIG_VIS_STIM + TRIG_KEY_UP`) | `'reading'` | `'Chunk_Change_up_chunk-<N>'` |
| Move down to next chunk | `10` (`TRIG_VIS_STIM + TRIG_KEY_DOWN`) | `'reading'` | `'Chunk_Change_down_chunk-<N>'` |
| Confirmed Escape exit | `16` (`TRIG_ESC`) | `'control'` | `'Task_End_Esc'` / `'Task_End_Esc_At_Intro'` |
