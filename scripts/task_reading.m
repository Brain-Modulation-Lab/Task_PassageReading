function task_reading(cfg)
% task_reading  Run the continuous passage-reading task (non-PsychToolbox).
%
% Presents a multi-paragraph text passage split into screen-sized chunks.
% Subject/experimenter steps backward/forward through chunks with Up/Down
% arrow keys. Events and TTL triggers are logged whenever on-screen text
% changes. Escape opens a confirmation dialog before ending the task.

%% ---- Default optional fields ----------------------------------------
if ~exist('cfg', 'var') || isempty(cfg)
    cfg = struct();
end
if ~isfield(cfg, 'SUBJECT') || isempty(cfg.SUBJECT)
    cfg.SUBJECT = 'qqq';
end
if ~isfield(cfg, 'stim_font_size') || isempty(cfg.stim_font_size)
    cfg.stim_font_size = 80;
end
if ~isfield(cfg, 'stim_font_name') || isempty(cfg.stim_font_name)
    cfg.stim_font_name = get(0, 'DefaultAxesFontName');
end
if ~isfield(cfg, 'stim_font_weight') || isempty(cfg.stim_font_weight)
    cfg.stim_font_weight = 'bold';
end
if ~isfield(cfg, 'text_color') || isempty(cfg.text_color)
    cfg.text_color = [1 1 1];
end
if ~isfield(cfg, 'background_color') || isempty(cfg.background_color)
    cfg.background_color = [0 0 0];
end
if ~isfield(cfg, 'screen_proportion') || isempty(cfg.screen_proportion)
    cfg.screen_proportion = 0.8;
end
if ~isfield(cfg, 'max_sentences_per_paragraph') || isempty(cfg.max_sentences_per_paragraph)
    cfg.max_sentences_per_paragraph = 3;
end
if ~isfield(cfg, 'key_cooldown') || isempty(cfg.key_cooldown)
    cfg.key_cooldown = 0.20; % minimum seconds between chunk transitions
end

%% ---- Validate configuration -----------------------------------------
if ~isfield(cfg, 'PATH_TASK') || ~isfolder(cfg.PATH_TASK)
    error('cfg.PATH_TASK missing or invalid.');
end
if ~isfield(cfg, 'EVENT_FILENAME') || ~isfield(cfg, 'STIM_FILENAME')
    error('cfg.EVENT_FILENAME and cfg.STIM_FILENAME are required.');
end
if ~isfield(cfg, 'stim_file') || isempty(cfg.stim_file)
    error('cfg.stim_file is required.');
end
if cfg.screen_proportion <= 0 || cfg.screen_proportion > 1
    error('cfg.screen_proportion must be in the range (0, 1].');
end

% Derive BIDS full-passage RTF and cfg JSON paths if not already provided
[stimOutDir, stimOutStem, ~] = fileparts(cfg.STIM_FILENAME);
bidsPrefix = regexprep(stimOutStem, '_stim$', '_');
if ~isfield(cfg, 'PASSAGE_FILENAME') || isempty(cfg.PASSAGE_FILENAME)
    cfg.PASSAGE_FILENAME = fullfile(stimOutDir, [bidsPrefix 'full-passage.rtf']);
end
if ~isfield(cfg, 'CFG_FILENAME') || isempty(cfg.CFG_FILENAME)
    cfg.CFG_FILENAME = fullfile(stimOutDir, [bidsPrefix 'cfg.json']);
end

% Normalize colors to [0, 1] RGB and check visibility contrast
cfg.text_color       = normalize_rgb_color(cfg.text_color);
cfg.background_color = normalize_rgb_color(cfg.background_color);
warn_if_low_contrast(cfg.text_color, cfg.background_color);

% Resolve stimulus file path
if isfile(cfg.stim_file)
    stim_filepath = cfg.stim_file;
elseif isfield(cfg, 'PATH_STIMDIR') && isfile(fullfile(cfg.PATH_STIMDIR, cfg.stim_file))
    stim_filepath = fullfile(cfg.PATH_STIMDIR, cfg.stim_file);
else
    error('Stimulus file not found: %s', cfg.stim_file);
end

%% ---- Ensure output directories exist & save cfg ---------------------
for fn = {'EVENT_FILENAME', 'STIM_FILENAME', 'PASSAGE_FILENAME', 'CFG_FILENAME'}
    d = fileparts(cfg.(fn{1}));
    if ~isempty(d) && ~isfolder(d), mkdir(d); end
end
save_cfg_files(cfg);

%% ---- .NET keyboard (Windows) + MATLAB figure key listener -----------
use_dotnet_keys = false;
try
    NET.addAssembly('PresentationCore');
    System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Escape);
    use_dotnet_keys = true;
catch
    use_dotnet_keys = false;
end
fprintf('Keyboard polling mode: .NET PresentationCore = %d (cooldown = %.2f s)\n', ...
    use_dotnet_keys, cfg.key_cooldown);

% Prevent Up/Down arrow keys from recalling MATLAB Command Window history while task runs
cmdWinKeyCleanup = suppress_cmdwin_up_down_history(); %#ok<NASGU>

%% ---- Timing helpers -------------------------------------------------
ticH  = tic;
t0abs = seconds(timeofday(datetime('now'))); % s-since-midnight at task start
T.now   = @()  t0abs + toc(ticH);
T.wait  = @(s) pause(max(0, s));

%% ---- Display setup & aspect-ratio proportional buffers --------------
ss           = get(0, 'ScreenSize'); % [left bottom width height] in px
screen_w_px  = ss(3);
screen_h_px  = ss(4);
aspect_ratio = screen_w_px / screen_h_px;

% Usable screen area and horizontal vs. vertical buffers proportional to aspect ratio
usable_w_px    = cfg.screen_proportion * screen_w_px;
usable_h_px    = cfg.screen_proportion * screen_h_px;
buf_horiz_px   = (screen_w_px - usable_w_px) / 2;
buf_vert_px    = (screen_h_px - usable_h_px) / 2;

buf_horiz_norm = buf_horiz_px / screen_w_px;
buf_vert_norm  = buf_vert_px  / screen_h_px;
usable_w_norm  = usable_w_px  / screen_w_px;
usable_h_norm  = usable_h_px  / screen_h_px;

fprintf('Screen: %dx%d px (aspect %.3f) | Proportion: %.2f | Buffers: H=%.1f px, V=%.1f px\n', ...
    screen_w_px, screen_h_px, aspect_ratio, cfg.screen_proportion, buf_horiz_px, buf_vert_px);

% Keyboard state updated by WindowKeyPressFcn (used as fallback when .NET is unavailable)
key_state = struct('any_pressed', false, 'last_key', '', 'pending_nav', '');

hfig = figure('Name', 'Reading Task', 'Color', cfg.background_color, ...
    'MenuBar', 'none', 'ToolBar', 'none', 'NumberTitle', 'off', ...
    'Visible', 'on', ...
    'Position', [0 0 screen_w_px screen_h_px], ...
    'WindowKeyPressFcn', @onWindowKeyPress);

% Bring stimulus window immediately to foreground
figure(hfig);
drawnow;

% Axes inset by aspect-ratio-proportional screen buffers
ax = axes('Parent', hfig, 'Units', 'normalized', ...
    'Position', [buf_horiz_norm, buf_vert_norm, usable_w_norm, usable_h_norm], ...
    'Visible', 'off');

hText = text(0.5, 0.5, '', 'Parent', ax, ...
    'Color', cfg.text_color, ...
    'FontName', cfg.stim_font_name, ...
    'FontSize', cfg.stim_font_size, ...
    'FontWeight', cfg.stim_font_weight, ...
    'HorizontalAlignment', 'center', ...
    'VerticalAlignment', 'middle', ...
    'Units', 'normalized', ...
    'Interpreter', 'none');

% Photodiode square in top-left corner of full screen
pdLen   = 0.05;
hSquare = annotation('rectangle', 'FaceColor', [1 1 1], 'EdgeColor', 'none', ...
    'Position', [0, 1 - pdLen, pdLen, pdLen]);

%% ---- Read passage, archive original RTF, split into chunks ----------
raw_passage_text = read_passage_file(stim_filepath);
save_original_passage_rtf(stim_filepath, raw_passage_text, cfg.PASSAGE_FILENAME);

[chunks_display, chunks_tsv_str] = split_passage_into_chunks( ...
    raw_passage_text, cfg, usable_w_px, usable_h_px, hfig);

n_chunks = numel(chunks_display);
if n_chunks == 0
    close(hfig);
    error('No readable text chunks could be extracted from: %s', stim_filepath);
end

stim_table = table((1:n_chunks)', chunks_tsv_str(:), ...
    'VariableNames', {'chunk_id', 'stim'});
writetable(stim_table, cfg.STIM_FILENAME, ...
    'Delimiter', '\t', 'FileType', 'text', 'WriteVariableNames', true);
fprintf('Saved %d text chunks to %s\n', n_chunks, cfg.STIM_FILENAME);

% Sanitize strings for single-line double-quoted fields in events.tsv
chunks_event_str = cellfun(@sanitize_for_event_tsv, chunks_tsv_str, 'UniformOutput', false);

%% ---- Open Event Log (BIDS TSV header) -------------------------------
eventFH = fopen(cfg.EVENT_FILENAME, 'w');
if eventFH == -1
    close(hfig);
    error('Could not open event file for writing: %s', cfg.EVENT_FILENAME);
end
eventCleanup = onCleanup(@() safe_fclose(eventFH)); %#ok<NASGU>
fprintf(eventFH, 'onset\tduration\tsample\ttrial_type\tstim\tvalue\tevent_code\n');

%% ---- Trigger codes --------------------------------------------------
TRIG_INTRO    = 1;
TRIG_VIS_STIM = 2;
TRIG_KEY_UP   = 4;
TRIG_KEY_DOWN = 8;
TRIG_ESC      = 16;

doDigOut  = isfield(cfg, 'DIGOUT') && logical(cfg.DIGOUT) && (exist('xippmex', 'file') == 3);
flipState = 0;

%% ---- Intro Screen ---------------------------------------------------
intro_text = sprintf('Passage reading\n\nPress any key to proceed');
set(hText, 'String', intro_text, 'Color', cfg.text_color, ...
    'FontName', cfg.stim_font_name, 'FontSize', cfg.stim_font_size, ...
    'FontWeight', cfg.stim_font_weight);
set(hSquare, 'FaceColor', [0.3 0.3 0.3]);
figure(hfig);
drawnow;

tIntroOn  = T.now();
flipState = ~flipState;
log_event(eventFH, doDigOut, tIntroOn, [], [], 'control', ...
    sanitize_for_event_tsv(intro_text), TRIG_INTRO, 'Intro_Onset', flipState);
fprintf('Intro screen displayed. Waiting for any key to proceed...\n');

% Brief settle, then snapshot currently-down keys so Enter from launch or latched keys don't skip/freeze intro
T.wait(0.25);
drawnow;
baseline_down         = get_dotnet_key_mask(use_dotnet_keys);
key_state.any_pressed = false;
key_state.pending_nav = '';

% Wait for any new key press (or Escape confirmation dialog)
while true
    if ~ishandle(hfig)
        return;
    end

    [esc_down, ~, ~] = poll_keys(use_dotnet_keys);
    if (use_dotnet_keys && esc_down) || (~use_dotnet_keys && strcmp(key_state.pending_nav, 'escape'))
        key_state.pending_nav = '';
        if confirm_exit_dialog(hfig)
            flipState = ~flipState;
            log_event(eventFH, doDigOut, T.now(), [], [], 'control', [], TRIG_ESC, 'Task_End_Esc_At_Intro', flipState);
            set(hText, 'String', ''); drawnow;
            if ishandle(hfig), close(hfig); end
            return;
        end
        wait_for_esc_release(use_dotnet_keys);
        baseline_down         = get_dotnet_key_mask(use_dotnet_keys);
        key_state.any_pressed = false;
        key_state.pending_nav = '';
        continue;
    end

    new_dotnet_key = false;
    if use_dotnet_keys
        curr_down      = get_dotnet_key_mask(true);
        baseline_down  = baseline_down & curr_down; % clear keys once released
        new_dotnet_key = any(curr_down & ~baseline_down);
    end

    if (~use_dotnet_keys && key_state.any_pressed) || new_dotnet_key
        break;
    end

    drawnow limitrate;
    T.wait(0.01);
end

%% ---- Transition from Intro Screen to First Chunk --------------------
curr_chunk = 1;
set(hText, 'String', chunks_display{curr_chunk});
set(hSquare, 'FaceColor', [0 0 0]);
drawnow;

tFirstChunkOn = T.now();
flipState     = ~flipState;
log_event(eventFH, doDigOut, tFirstChunkOn, [], [], 'reading', ...
    chunks_event_str{curr_chunk}, TRIG_VIS_STIM, ...
    sprintf('Chunk_Change_start_chunk-%d', curr_chunk), flipState);

[first_words, last_words] = get_chunk_preview(chunks_display{curr_chunk}, 4);
fprintf('[START] Switched to text chunk %d/%d  |  "%s ... %s"\n', ...
    curr_chunk, n_chunks, first_words, last_words);

% Bounded wait for navigation/action keys to release so intro keypress doesn't double-trigger
wait_for_nav_keys_release(use_dotnet_keys);
key_state.pending_nav = '';
[prev_esc_down, prev_up_down, prev_dn_down] = poll_keys(use_dotnet_keys);
last_nav_tic = tic;

%% ---- Main Passage Navigation Loop (Up / Down / Escape) --------------
while ishandle(hfig)
    [esc_down, up_down, dn_down] = poll_keys(use_dotnet_keys);
    cooldown_ok = (toc(last_nav_tic) >= cfg.key_cooldown);

    if use_dotnet_keys
        % Physical rising-edge detection + debounce cooldown (no OS auto-repeat or duplicate figure events)
        esc_triggered = esc_down && ~prev_esc_down;
        up_triggered  = up_down  && ~prev_up_down && cooldown_ok;
        dn_triggered  = dn_down  && ~prev_dn_down && cooldown_ok;
    else
        % Fallback for macOS/Linux without .NET PresentationCore
        esc_triggered = strcmp(key_state.pending_nav, 'escape');
        up_triggered  = strcmp(key_state.pending_nav, 'up')   && cooldown_ok;
        dn_triggered  = strcmp(key_state.pending_nav, 'down') && cooldown_ok;
    end

    prev_esc_down = esc_down;
    prev_up_down  = up_down;
    prev_dn_down  = dn_down;
    key_state.pending_nav = '';

    % 1. Escape key -> confirmation dialog box
    if esc_triggered
        if confirm_exit_dialog(hfig)
            flipState = ~flipState;
            log_event(eventFH, doDigOut, T.now(), [], [], 'control', [], TRIG_ESC, 'Task_End_Esc', flipState);
            fprintf('ESC confirmed -- ending reading task at chunk %d/%d.\n', curr_chunk, n_chunks);
            break;
        else
            wait_for_esc_release(use_dotnet_keys);
            [prev_esc_down, prev_up_down, prev_dn_down] = poll_keys(use_dotnet_keys);
            key_state.pending_nav = '';
            last_nav_tic = tic;
        end
    end

    % 2. Up arrow -> previous chunk
    if up_triggered
        last_nav_tic = tic;
        if curr_chunk > 1
            curr_chunk = curr_chunk - 1;
            set(hText, 'String', chunks_display{curr_chunk});
            if mod(curr_chunk, 2) == 1
                set(hSquare, 'FaceColor', [0 0 0]);
            else
                set(hSquare, 'FaceColor', [1 1 1]);
            end
            drawnow;

            tSwitch   = T.now();
            flipState = ~flipState;
            log_event(eventFH, doDigOut, tSwitch, [], [], 'reading', ...
                chunks_event_str{curr_chunk}, TRIG_VIS_STIM + TRIG_KEY_UP, ...
                sprintf('Chunk_Change_up_chunk-%d', curr_chunk), flipState);

            [first_words, last_words] = get_chunk_preview(chunks_display{curr_chunk}, 4);
            fprintf('[UP] Switched to text chunk %d/%d  |  "%s ... %s"\n', ...
                curr_chunk, n_chunks, first_words, last_words);
        else
            % Boundary hit: do NOT log event, only print cmdline message
            fprintf('[UP] Failed to move: already at top of passage (text chunk %d/%d).\n', ...
                curr_chunk, n_chunks);
        end
    end

    % 3. Down arrow -> next chunk
    if dn_triggered
        last_nav_tic = tic;
        if curr_chunk < n_chunks
            curr_chunk = curr_chunk + 1;
            set(hText, 'String', chunks_display{curr_chunk});
            if mod(curr_chunk, 2) == 1
                set(hSquare, 'FaceColor', [0 0 0]);
            else
                set(hSquare, 'FaceColor', [1 1 1]);
            end
            drawnow;

            tSwitch   = T.now();
            flipState = ~flipState;
            log_event(eventFH, doDigOut, tSwitch, [], [], 'reading', ...
                chunks_event_str{curr_chunk}, TRIG_VIS_STIM + TRIG_KEY_DOWN, ...
                sprintf('Chunk_Change_down_chunk-%d', curr_chunk), flipState);

            [first_words, last_words] = get_chunk_preview(chunks_display{curr_chunk}, 4);
            fprintf('[DOWN] Switched to text chunk %d/%d  |  "%s ... %s"\n', ...
                curr_chunk, n_chunks, first_words, last_words);
        else
            % Boundary hit: do NOT log event, only print cmdline message
            fprintf('[DOWN] Failed to move: already at bottom of passage (text chunk %d/%d).\n', ...
                curr_chunk, n_chunks);
        end
    end

    drawnow limitrate;
    T.wait(0.01);
end

%% ---- Cleanup --------------------------------------------------------
if ishandle(hfig)
    set(hText, 'String', '');
    set(hSquare, 'FaceColor', [1 1 1]);
    drawnow;
    close(hfig);
end
fprintf('Reading task complete.\n');

%% =================== Nested & Local Functions ========================

    function onWindowKeyPress(~, evt)
        key_state.any_pressed = true;
        key_state.last_key    = evt.Key;
        switch evt.Key
            case 'uparrow'
                key_state.pending_nav = 'up';
            case 'downarrow'
                key_state.pending_nav = 'down';
            case 'escape'
                key_state.pending_nav = 'escape';
        end
    end

    function [esc, up, dn] = poll_keys(use_dotnet)
        esc = false;
        up  = false;
        dn  = false;
        if use_dotnet
            esc = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Escape);
            up  = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Up);
            dn  = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Down);
        end
    end

    function wait_for_esc_release(use_dotnet)
        if use_dotnet
            tStart = tic;
            while System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Escape) && toc(tStart) < 0.5
                T.wait(0.01);
            end
        else
            T.wait(0.15);
        end
    end

    function wait_for_nav_keys_release(use_dotnet)
        if use_dotnet
            tStart = tic;
            while toc(tStart) < 0.35
                esc = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Escape);
                up  = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Up);
                dn  = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Down);
                sp  = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Space);
                rt  = System.Windows.Input.Keyboard.IsKeyDown(System.Windows.Input.Key.Return);
                if ~(esc || up || dn || sp || rt)
                    break;
                end
                T.wait(0.01);
            end
        else
            T.wait(0.15);
        end
    end

end % task_reading


%% =================== BIDS Archive Helpers (cfg & full-passage) =======

function save_cfg_files(cfg)
% Saves cfg as BIDS-formatted JSON (and companion .mat file).
    jsonPath = cfg.CFG_FILENAME;
    try
        jsonStr = jsonencode(cfg, 'PrettyPrint', true);
    catch
        jsonStr = jsonencode(cfg);
    end

    fid = fopen(jsonPath, 'w', 'n', 'UTF-8');
    if fid == -1
        error('Could not open cfg JSON file for writing: %s', jsonPath);
    end
    c = onCleanup(@() safe_fclose(fid)); %#ok<NASGU>
    fwrite(fid, jsonStr, 'char');
    fprintf('Saved task configuration to %s\n', jsonPath);

    [cfgDir, cfgStem, ~] = fileparts(jsonPath);
    matPath = fullfile(cfgDir, [cfgStem '.mat']);
    save(matPath, 'cfg');
end

function save_original_passage_rtf(stim_filepath, raw_passage_text, out_rtf_filepath)
% Archives the original unchunked passage in BIDS-formatted *_full-passage.rtf.
[~, ~, ext] = fileparts(stim_filepath);
if strcmpi(ext, '.rtf') && isfile(stim_filepath)
    copyfile(stim_filepath, out_rtf_filepath);
    fprintf('Copied original RTF passage to %s\n', out_rtf_filepath);
    return;
end

txt = regexprep(raw_passage_text, '\r\n|\r', '\n');
txt = strtrim(txt);

% Split on paragraph breaks and escape RTF control characters per paragraph
paras    = regexp(txt, '\n\s*\n', 'split');
rtfParas = cell(size(paras));
for ip = 1:numel(paras)
    p = strtrim(paras{ip});
    p = escape_rtf_text(p);
    p = regexprep(p, '\n', '\\line ');
    rtfParas{ip} = p;
end

rtfHeader = ['{\rtf1\ansi\deff0', ...
    '{\fonttbl{\f0\fnil\fcharset0 Helvetica;}}', ...
    '\viewkind4\uc1\pard\f0\fs24 '];
% Double-escape '\\par' because MATLAB's strjoin interprets backslash escapes in the delimiter
rtfBody = strjoin(rtfParas, ['\\par\\par ', newline]);
rtfDoc  = [rtfHeader, rtfBody, '\par', newline, '}'];

fid = fopen(out_rtf_filepath, 'w', 'n', 'UTF-8');
if fid == -1
    error('Could not open full-passage RTF file for writing: %s', out_rtf_filepath);
end
c = onCleanup(@() safe_fclose(fid)); %#ok<NASGU>
fwrite(fid, rtfDoc, 'char');
fprintf('Saved original passage RTF to %s\n', out_rtf_filepath);
end

function escaped = escape_rtf_text(str_in)
    str_in = strrep(str_in, '\', '\\');
    str_in = strrep(str_in, '{', '\{');
    str_in = strrep(str_in, '}', '\}');

    codes = double(str_in);
    if all(codes <= 127)
        escaped = str_in;
        return;
    end

    outParts = cell(1, numel(codes));
    for k = 1:numel(codes)
        c = codes(k);
        if c <= 127
            outParts{k} = str_in(k);
        else
            if c > 32767
                cSigned = c - 65536;
            else
                cSigned = c;
            end
            outParts{k} = sprintf('\\u%d?', cSigned);
        end
    end
    escaped = [outParts{:}];
end


%% =================== Command Window Arrow-History Suppression ========

function cleanupObj = suppress_cmdwin_up_down_history()
% Suppresses Up/Down arrow command-history recall in the MATLAB Command
% Window while task_reading is running, restoring original bindings on exit.
    cleanupObj = [];
    try
        jDesktop = com.mathworks.mde.desk.MLDesktop.getInstance;
        jCmdWin  = jDesktop.getClient('Command Window');
        xView    = find_java_component_by_class(jCmdWin, 'XCmdWndView');
        if isempty(xView)
            return;
        end

        ksUp   = javax.swing.KeyStroke.getKeyStroke(java.awt.event.KeyEvent.VK_UP, 0);
        ksDown = javax.swing.KeyStroke.getKeyStroke(java.awt.event.KeyEvent.VK_DOWN, 0);

        conds = [ ...
            javax.swing.JComponent.WHEN_FOCUSED, ...
            javax.swing.JComponent.WHEN_ANCESTOR_OF_FOCUSED_COMPONENT, ...
            javax.swing.JComponent.WHEN_IN_FOCUSED_WINDOW ...
        ];

        savedMaps = cell(numel(conds), 5);
        for ic = 1:numel(conds)
            im = xView.getInputMap(conds(ic));
            localKeys = im.keys();
            hasLocalUp   = false;
            hasLocalDown = false;
            if ~isempty(localKeys)
                for ik = 1:numel(localKeys)
                    if localKeys(ik).equals(ksUp),   hasLocalUp   = true; end
                    if localKeys(ik).equals(ksDown), hasLocalDown = true; end
                end
            end
            savedMaps{ic, 1} = im;
            savedMaps{ic, 2} = hasLocalUp;
            savedMaps{ic, 3} = im.get(ksUp);
            savedMaps{ic, 4} = hasLocalDown;
            savedMaps{ic, 5} = im.get(ksDown);

            im.put(ksUp,   'none');
            im.put(ksDown, 'none');
        end

        % Place our KeyPressedCallback ahead of existing KeyListeners to consume VK_UP / VK_DOWN
        origListeners = xView.getKeyListeners();
        for il = 1:numel(origListeners)
            xView.removeKeyListener(origListeners(il));
        end

        hView = handle(xView, 'CallbackProperties');
        set(hView, 'KeyPressedCallback', @consumeUpDownKeyEvent);

        for il = 1:numel(origListeners)
            xView.addKeyListener(origListeners(il));
        end

        cleanupObj = onCleanup(@() restore_cmdwin_up_down_history(hView, savedMaps, ksUp, ksDown));
    catch
        cleanupObj = [];
    end
end

function target = find_java_component_by_class(comp, classSubstr)
    target = [];
    if isempty(comp)
        return;
    end
    try
        if contains(char(comp.getClass().getName()), classSubstr)
            target = comp;
            return;
        end
        n = comp.getComponentCount();
        for i = 0:(n - 1)
            target = find_java_component_by_class(comp.getComponent(i), classSubstr);
            if ~isempty(target)
                return;
            end
        end
    catch
    end
end

function consumeUpDownKeyEvent(~, jEvent)
    try
        kc = jEvent.getKeyCode();
        if kc == java.awt.event.KeyEvent.VK_UP || kc == java.awt.event.KeyEvent.VK_DOWN
            jEvent.consume();
        end
    catch
    end
end

function restore_cmdwin_up_down_history(hView, savedMaps, ksUp, ksDown)
    try
        if ~isempty(hView) && ishandle(hView)
            set(hView, 'KeyPressedCallback', []);
        end
    catch
    end
    try
        for ic = 1:size(savedMaps, 1)
            im           = savedMaps{ic, 1};
            hasLocalUp   = savedMaps{ic, 2};
            origUp       = savedMaps{ic, 3};
            hasLocalDown = savedMaps{ic, 4};
            origDown     = savedMaps{ic, 5};

            if hasLocalUp
                im.put(ksUp, origUp);
            else
                im.remove(ksUp);
            end
            if hasLocalDown
                im.put(ksDown, origDown);
            else
                im.remove(ksDown);
            end
        end
    catch
    end
end


%% =================== Color Validation Helpers ========================

function rgb = normalize_rgb_color(col)
    if ischar(col) || isstring(col)
        switch lower(char(col))
            case {'w', 'white'},   rgb = [1 1 1];
            case {'k', 'black'},   rgb = [0 0 0];
            case {'r', 'red'},     rgb = [1 0 0];
            case {'g', 'green'},   rgb = [0 1 0];
            case {'b', 'blue'},    rgb = [0 0 1];
            case {'y', 'yellow'},  rgb = [1 1 0];
            case {'c', 'cyan'},    rgb = [0 1 1];
            case {'m', 'magenta'}, rgb = [1 0 1];
            case {'gray', 'grey'}, rgb = [0.5 0.5 0.5];
            otherwise
                error('Unrecognized color string: %s', char(col));
        end
    elseif isnumeric(col) && numel(col) == 3
        rgb = double(col(:)');
        if any(rgb > 1)
            rgb = rgb / 255;
        end
        if any(rgb < 0) || any(rgb > 1)
            error('RGB color values must be within [0, 1] or [0, 255].');
        end
    else
        error('Color must be a 3-element RGB vector or color name.');
    end
end

function warn_if_low_contrast(fg, bg)
    rgb_dist = norm(fg - bg);
    lum_fg   = 0.2126 * fg(1) + 0.7152 * fg(2) + 0.0722 * fg(3);
    lum_bg   = 0.2126 * bg(1) + 0.7152 * bg(2) + 0.0722 * bg(3);
    lum_diff = abs(lum_fg - lum_bg);

    if rgb_dist < 0.30 || lum_diff < 0.25
        msg = sprintf(['Warning: text_color [%.2f %.2f %.2f] and background_color [%.2f %.2f %.2f] ', ...
            'are very close to each other (RGB distance = %.2f, luminance diff = %.2f).\n\n', ...
            'The passage text may be difficult or impossible to read on screen.'], ...
            fg(1), fg(2), fg(3), bg(1), bg(2), bg(3), rgb_dist, lum_diff);
        warning('%s', strrep(msg, sprintf('\n'), ' '));
        hWarn = warndlg(msg, 'Low Text/Background Contrast Warning', 'modal');
        uiwait(hWarn);
    end
end


%% =================== Exit Confirmation Dialog ========================

function do_exit = confirm_exit_dialog(hfig)
    if ishandle(hfig)
        drawnow;
    end
    choice = questdlg( ...
        'Escape key pressed. Do you want to end the reading task?', ...
        'End Reading Task?', ...
        'End Task', 'Continue Reading', 'Continue Reading');
    do_exit = strcmp(choice, 'End Task');
    if ~do_exit && ishandle(hfig)
        figure(hfig);
        drawnow;
    end
end


%% =================== Keyboard Helper (.NET) ==========================

function mask = get_dotnet_key_mask(use_dotnet)
    persistent keyList
    if isempty(keyList)
        keyNames = [ ...
            {'Space', 'Return', 'Tab', 'Back', 'Delete', ...
             'Up', 'Down', 'Left', 'Right', 'PageUp', 'PageDown', 'Home', 'End'}, ...
            arrayfun(@(c) char(c), 'A':'Z', 'UniformOutput', false), ...
            arrayfun(@(d) sprintf('D%d', d), 0:9, 'UniformOutput', false), ...
            arrayfun(@(d) sprintf('NumPad%d', d), 0:9, 'UniformOutput', false), ...
            arrayfun(@(f) sprintf('F%d', f), 1:12, 'UniformOutput', false) ...
        ];
        keyList = cell(numel(keyNames), 1);
        idx = 0;
        for i = 1:numel(keyNames)
            try
                keyList{idx + 1} = System.Windows.Input.Key.(keyNames{i});
                idx = idx + 1;
            catch
            end
        end
        keyList = keyList(1:idx);
    end

    mask = false(numel(keyList), 1);
    if ~use_dotnet
        return;
    end

    for i = 1:numel(keyList)
        try
            mask(i) = System.Windows.Input.Keyboard.IsKeyDown(keyList{i});
        catch
            mask(i) = false;
        end
    end
end


%% =================== Multi-Format Document Reader ====================

function raw_text = read_passage_file(filepath)
    [~, ~, ext] = fileparts(filepath);
    ext = lower(ext);

    switch ext
        case {'.txt', '.md', '.text', '.log'}
            fid = fopen(filepath, 'r', 'n', 'UTF-8');
            if fid == -1, error('Cannot open file: %s', filepath); end
            c = onCleanup(@() fclose(fid)); %#ok<NASGU>
            raw_text = fread(fid, '*char')';
            if ~isempty(raw_text) && double(raw_text(1)) == 65279
                raw_text = raw_text(2:end);
            end
            raw_text = regexprep(raw_text, '\r\n|\r', '\n');
            if isempty(regexp(raw_text, '\n\s*\n', 'once'))
                raw_text = regexprep(raw_text, '\n+', '\n\n');
            end

        case '.docx'
            raw_text = read_docx_native(filepath);

        case '.rtf'
            raw_text = read_rtf_native(filepath);

        case {'.html', '.htm', '.xml'}
            fid = fopen(filepath, 'r', 'n', 'UTF-8');
            if fid == -1, error('Cannot open file: %s', filepath); end
            c = onCleanup(@() fclose(fid)); %#ok<NASGU>
            html_str = fread(fid, '*char')';
            html_str = regexprep(html_str, '<(script|style)[^>]*>.*?</\1>', '', 'ignorecase');
            html_str = regexprep(html_str, '<(br|p|div|li|h[1-6])[^>]*>', '\n\n', 'ignorecase');
            html_str = regexprep(html_str, '<[^>]+>', '');
            html_str = decode_html_entities(html_str);
            raw_text = html_str;

        case {'.pdf', '.doc', '.odt'}
            if exist('extractFileText', 'file') == 2
                raw_text = char(extractFileText(filepath));
                raw_text = regexprep(raw_text, '\r\n|\r', '\n');
            elseif ispc
                raw_text = read_via_word_com(filepath);
            else
                error('Format "%s" requires MATLAB Text Analytics Toolbox (extractFileText) or Windows Word COM.', ext);
            end

        otherwise
            if exist('extractFileText', 'file') == 2
                raw_text = char(extractFileText(filepath));
                raw_text = regexprep(raw_text, '\r\n|\r', '\n');
            else
                fid = fopen(filepath, 'r', 'n', 'UTF-8');
                if fid == -1, error('Unsupported or unreadable file: %s', filepath); end
                c = onCleanup(@() fclose(fid)); %#ok<NASGU>
                raw_text = fread(fid, '*char')';
                raw_text = regexprep(raw_text, '\r\n|\r', '\n');
            end
    end
end

function txt = read_docx_native(filepath)
    tmpDir = tempname;
    mkdir(tmpDir);
    cleanupTmp = onCleanup(@() rmdir(tmpDir, 's')); %#ok<NASGU>

    unzip(filepath, tmpDir);
    xmlPath = fullfile(tmpDir, 'word', 'document.xml');
    if ~isfile(xmlPath)
        error('Invalid .docx file (missing word/document.xml): %s', filepath);
    end

    docNode = xmlread(xmlPath);
    pNodes  = docNode.getElementsByTagName('w:p');
    nP      = pNodes.getLength;
    paras   = cell(nP, 1);
    count   = 0;

    for i = 0:(nP - 1)
        pNode = pNodes.item(i);
        pText = extract_docx_paragraph_text(pNode);
        pText = strtrim(pText);
        if ~isempty(pText)
            count = count + 1;
            paras{count} = pText;
        end
    end
    txt = strjoin(paras(1:count), '\n\n');
end

function str = extract_docx_paragraph_text(node)
    str = '';
    if ~node.hasChildNodes
        return;
    end
    children = node.getChildNodes;
    for k = 0:(children.getLength - 1)
        ch   = children.item(k);
        name = char(ch.getNodeName);
        if strcmp(name, 'w:t')
            str = [str, char(ch.getTextContent)]; %#ok<AGROW>
        elseif strcmp(name, 'w:tab')
            str = [str, ' ']; %#ok<AGROW>
        elseif strcmp(name, 'w:br') || strcmp(name, 'w:cr')
            str = [str, newline]; %#ok<AGROW>
        else
            str = [str, extract_docx_paragraph_text(ch)]; %#ok<AGROW>
        end
    end
end

function txt = read_rtf_native(filepath)
    fid = fopen(filepath, 'r', 'n', 'UTF-8');
    if fid == -1, error('Cannot open RTF file: %s', filepath); end
    c = onCleanup(@() fclose(fid)); %#ok<NASGU>
    rtf = fread(fid, '*char')';

    skipGroups = {'fonttbl', 'colortbl', 'stylesheet', 'info', 'pict', 'header', 'footer', 'footnote'};
    for ig = 1:numel(skipGroups)
        rtf = remove_rtf_group(rtf, skipGroups{ig});
    end

    hexTokens = regexp(rtf, '\\''([0-9a-fA-F]{2})', 'tokens');
    for ih = 1:numel(hexTokens)
        h = hexTokens{ih}{1};
        ch = char(hex2dec(h));
        rtf = strrep(rtf, ['\''' h], ch);
    end

    rtf = regexprep(rtf, '\\u(-?\d+)\??', '${char(mod(str2double($1), 65536))}');
    rtf = regexprep(rtf, '\\par\b\s*', '\n\n');
    rtf = regexprep(rtf, '\\line\b\s*', '\n');
    rtf = regexprep(rtf, '\\tab\b\s*', ' ');

    rtf = regexprep(rtf, '\\[a-zA-Z]+-?\d*\s?', '');
    rtf = regexprep(rtf, '\\[^a-zA-Z]', '');
    rtf = strrep(rtf, '{', '');
    rtf = strrep(rtf, '}', '');
    txt = strtrim(rtf);
end

function rtf = remove_rtf_group(rtf, groupName)
    pattern = ['\{\\\*?' groupName '\b'];
    idx = regexp(rtf, pattern, 'once');
    while ~isempty(idx)
        depth = 0;
        endIdx = length(rtf);
        for k = idx:length(rtf)
            if rtf(k) == '{'
                depth = depth + 1;
            elseif rtf(k) == '}'
                depth = depth - 1;
                if depth == 0
                    endIdx = k;
                    break;
                end
            end
        end
        rtf(idx:endIdx) = [];
        idx = regexp(rtf, pattern, 'once');
    end
end

function txt = read_via_word_com(filepath)
    word = actxserver('Word.Application');
    word.Visible = false;
    c = onCleanup(@() invoke(word, 'Quit')); %#ok<NASGU>
    doc = word.Documents.Open(filepath, false, true);
    cDoc = onCleanup(@() invoke(doc, 'Close', false)); %#ok<NASGU>
    txt = doc.Content.Text;
    txt = regexprep(txt, '\r\n|\r', '\n\n');
end

function s = decode_html_entities(s)
    s = strrep(s, '&nbsp;', ' ');
    s = strrep(s, '&amp;',  '&');
    s = strrep(s, '&lt;',   '<');
    s = strrep(s, '&gt;',   '>');
    s = strrep(s, '&quot;', '"');
    s = strrep(s, '&#39;',  '''');
end


%% =================== Paragraph Splitting & Screen Chunking ===========

function [chunks_display, chunks_tsv_str] = split_passage_into_chunks(raw_text, cfg, usable_w_px, usable_h_px, hfig)
    raw_text = regexprep(raw_text, '\r\n|\r', '\n');
    raw_text = strtrim(raw_text);

    % 1. Preserve existing paragraph breaks
    orig_paras = regexp(raw_text, '\n\s*\n', 'split');
    orig_paras = cellfun(@strtrim, orig_paras, 'UniformOutput', false);
    orig_paras = orig_paras(~cellfun(@isempty, orig_paras));

    % Collapse any internal soft line wraps within an existing paragraph into single spaces
    orig_paras = cellfun(@(p) regexprep(p, '\s+', ' '), orig_paras, 'UniformOutput', false);

    % 2. Split paragraphs longer than max_sentences_per_paragraph (indicated by periods)
    max_sents = cfg.max_sentences_per_paragraph;
    final_paras = {};
    for ip = 1:numel(orig_paras)
        sents = split_sentences_by_period(orig_paras{ip});
        if numel(sents) <= max_sents
            final_paras{end+1} = orig_paras{ip}; %#ok<AGROW>
        else
            for startIdx = 1:max_sents:numel(sents)
                endIdx = min(startIdx + max_sents - 1, numel(sents));
                final_paras{end+1} = strjoin(sents(startIdx:endIdx), ' '); %#ok<AGROW>
            end
        end
    end

    % 3. Create invisible measurement text object in pixels matching display style
    axMeas = axes('Parent', hfig, 'Units', 'pixels', ...
        'Position', [0 0 usable_w_px usable_h_px], 'Visible', 'off');
    hMeas = text(0, 0, '', 'Parent', axMeas, 'Units', 'pixels', ...
        'FontName', cfg.stim_font_name, ...
        'FontSize', cfg.stim_font_size, ...
        'FontWeight', cfg.stim_font_weight, ...
        'Interpreter', 'none', ...
        'Visible', 'off');
    cleanupMeas = onCleanup(@() delete(axMeas)); %#ok<NASGU>

    % 4. Word-wrap each paragraph to usable_w_px
    wrapped_paras = cell(numel(final_paras), 1);
    for ip = 1:numel(final_paras)
        wrapped_paras{ip} = wrap_paragraph_to_width(final_paras{ip}, usable_w_px, hMeas);
    end

    % 5. Group wrapped paragraphs into screen-sized chunks fitting within usable_h_px,
    %    preserving whole sentences across chunk boundaries whenever possible.
    chunks_display = {};
    curr_chunk_str = '';

    for ip = 1:numel(wrapped_paras)
        p_raw = final_paras{ip};
        p_str = wrapped_paras{ip};

        if isempty(curr_chunk_str)
            candidate = p_str;
        else
            candidate = [curr_chunk_str, newline, newline, p_str];
        end

        set(hMeas, 'String', candidate);
        ext = get(hMeas, 'Extent'); % [left bottom width height] in px

        if ext(4) <= usable_h_px
            curr_chunk_str = candidate;
        else
            % Flush accumulated chunk so this paragraph starts on a fresh screen
            if ~isempty(curr_chunk_str)
                chunks_display{end+1} = curr_chunk_str; %#ok<AGROW>
                curr_chunk_str = '';
            end

            % Check if this single paragraph fits on a fresh screen
            set(hMeas, 'String', p_str);
            extSingle = get(hMeas, 'Extent');
            if extSingle(4) <= usable_h_px
                curr_chunk_str = p_str;
            else
                % Single paragraph exceeds usable_h_px: split by whole sentences first
                sents   = split_sentences_by_period(p_raw);
                subText = '';

                for is = 1:numel(sents)
                    s = sents{is};
                    if isempty(subText)
                        candText = s;
                    else
                        candText = [subText, ' ', s];
                    end

                    candWrapped = wrap_paragraph_to_width(candText, usable_w_px, hMeas);
                    set(hMeas, 'String', candWrapped);
                    extSent = get(hMeas, 'Extent');

                    if extSent(4) <= usable_h_px
                        subText = candText;
                    else
                        % Adding sentence s overflows the screen: flush completed sentences
                        if ~isempty(subText)
                            chunks_display{end+1} = wrap_paragraph_to_width(subText, usable_w_px, hMeas); %#ok<AGROW>
                            subText = '';
                        end

                        % Check if sentence s fits intact on a fresh screen
                        sWrapped = wrap_paragraph_to_width(s, usable_w_px, hMeas);
                        set(hMeas, 'String', sWrapped);
                        extOneSent = get(hMeas, 'Extent');

                        if extOneSent(4) <= usable_h_px
                            subText = s;
                        else
                            % Single sentence alone exceeds usable_h_px: fall back to wrapped lines
                            sLines  = strsplit(sWrapped, '\n');
                            lineAcc = '';
                            for il = 1:numel(sLines)
                                candLine = sLines{il};
                                if ~isempty(lineAcc)
                                    candLine = [lineAcc, newline, sLines{il}];
                                end
                                set(hMeas, 'String', candLine);
                                extLine = get(hMeas, 'Extent');
                                if extLine(4) <= usable_h_px || isempty(lineAcc)
                                    lineAcc = candLine;
                                else
                                    chunks_display{end+1} = lineAcc; %#ok<AGROW>
                                    lineAcc = sLines{il};
                                end
                            end
                            if ~isempty(lineAcc)
                                chunks_display{end+1} = lineAcc; %#ok<AGROW>
                            end
                            subText = '';
                        end
                    end
                end

                if ~isempty(subText)
                    curr_chunk_str = wrap_paragraph_to_width(subText, usable_w_px, hMeas);
                end
            end
        end
    end

    if ~isempty(curr_chunk_str)
        chunks_display{end+1} = curr_chunk_str;
    end

    % 6. Format TSV column 'stim' using '\\' for linebreaks ('\\\\' for paragraph breaks)
    chunks_tsv_str = cell(size(chunks_display));
    for ic = 1:numel(chunks_display)
        s = chunks_display{ic};
        s = strrep(s, [newline, newline], '\\\\');
        s = strrep(s, newline, '\\');
        chunks_tsv_str{ic} = s;
    end
end

function sents = split_sentences_by_period(para_str)
    placeholder = char(1);
    protected = regexprep(para_str, '(?<=\d)\.(?=\d)', placeholder);
    protected = regexprep(protected, ...
        '\b(Mr|Mrs|Ms|Dr|Prof|Sr|Jr|St|vs|etc|Fig|Eq|Ref|al)\.', ...
        ['$1' placeholder], 'ignorecase');
    protected = regexprep(protected, '\b(e\.g|i\.e|U\.S|U\.K)\.', ...
        '${strrep($0, ''.'', placeholder)}', 'ignorecase');

    closeChars = [char(34), char(39), ')', '\]', char(8221), char(8217)];
    splitPattern = ['(?<=[.!?][' closeChars ']{0,4})\s+'];
    parts = regexp(protected, splitPattern, 'split');
    parts = cellfun(@(s) strtrim(strrep(s, placeholder, '.')), parts, 'UniformOutput', false);
    sents = parts(~cellfun(@isempty, parts));
end

function wrapped = wrap_paragraph_to_width(para_str, max_w_px, hMeas)
    words = strsplit(strtrim(para_str));
    if isempty(words) || (numel(words) == 1 && isempty(words{1}))
        wrapped = '';
        return;
    end

    lines   = {};
    curLine = words{1};

    for iw = 2:numel(words)
        candLine = [curLine, ' ', words{iw}];
        set(hMeas, 'String', candLine);
        ext = get(hMeas, 'Extent');
        if ext(3) <= max_w_px
            curLine = candLine;
        else
            lines{end+1} = curLine; %#ok<AGROW>
            curLine = words{iw};
        end
    end
    lines{end+1} = curLine;
    wrapped = strjoin(lines, newline);
end


%% =================== Logging & Console Preview Helpers ===============

function out = sanitize_for_event_tsv(str_in)
    out = strrep(str_in, [newline, newline], '\\\\');
    out = strrep(out, newline, '\\');
    out = strrep(out, sprintf('\t'), ' ');
    out = strrep(out, '"', '''');
end

function [first_words, last_words] = get_chunk_preview(chunk_str, n_words)
    clean_str = strtrim(regexprep(chunk_str, '\s+', ' '));
    words = strsplit(clean_str);
    words = words(~cellfun(@isempty, words));
    if numel(words) <= n_words
        first_words = strjoin(words, ' ');
        last_words  = first_words;
    else
        first_words = strjoin(words(1:n_words), ' ');
        last_words  = strjoin(words(end-n_words+1:end), ' ');
    end
end

function safe_fclose(fid)
    if ~isempty(fid) && fid > 2
        try
            fclose(fid);
        catch
        end
    end
end