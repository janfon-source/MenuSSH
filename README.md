# MenuSSH 隨手SSH

A lightweight SSH and SFTP tool that lives in the macOS menu bar. Pick one of the servers in your `~/.ssh/config` with the connection button (the network icon) at the top left, and sign in to it in the built-in terminal (SSH mode), or browse its files, upload and download (SFTP mode).

住在 macOS 選單列的輕量 SSH / SFTP 工具。[中文說明在下方](#中文說明)。

## Features

- **Your `~/.ssh/config` is the server list**: the connection button (the network icon) at the top left of the toolbar drops down every Host named there (pointing at one shows where it connects, user@hostname:port); the icon turns the accent color while connected, and its tooltip and the status line name the server showing, read the way ssh reads it (`Host *` defaults, `Include` files); the ones connected are marked with a green dot. Right-click the menu bar icon to connect to any of them without opening the window first. Connect to Another Host… in the same menu reaches a server that isn't in the config (`user@host` or `user@host:port`), which then stays in the menu. Below come what can be done with the host showing: copy its ssh command, forget its saved passwords, close its tab. ssh, scp and other tools use the same file, so a connection set up here works there too.
- **Connection settings** (⇧⌘K, or the connection menu): every Host in `~/.ssh/config` and the files it includes, to add (＋), duplicate and delete, and to drag into order: the order in the file, which is the order of the connection menu (a block moves with the comments above it; `Host *` moved above other hosts brings a warning, as its settings would then override theirs). The one selected is shown in a form: name (one or more, or a pattern such as `*.example.com`), address (HostName), user, port, key file (with a Choose… button), jump host (ProxyJump), the server folder to start in once connected (SSH and SFTP both start there, such as `/var/www` or `~/site`) and the folder on this Mac for SFTP's left side (handy with synchronized browsing), and every other setting and comment of the block as text, kept as written. Nothing is written until Save, which checks for missing names, bad ports and names used twice; then only the blocks that changed are rewritten, and comments, `Match` blocks and the rest of the file stay as they were. The two folders are MenuSSH's own, so they're kept in the block as comments (`# MenuSSH StartFolder /var/www`), which ssh and other tools pass over. A new connection goes above `Host *`, so the defaults there don't override it. The file as it was is kept beside it as `config.menussh-backup`, and a config that's a link (to a dotfiles folder) stays a link. “Open in Text Editor…” is there for anything else.
- **Tabs for the connections**: under the toolbar, This Mac's tab comes first, always there and fixed at the left; each server opened from the connection menu gets a tab of its own, named after it. Click a tab to switch (⌃Tab / ⌃⇧Tab go to the next and previous); each keeps its own SSH session, SSH or SFTP mode and server folder as you left them. Drag a server's tab along the strip to reorder them. × closes the tab and ends that connection (⌥⌘D for the tab showing); a session ending on its own (`exit`, or the connection dropping) closes its tab too. This Mac's tab can't be closed.
- **SSH and SFTP modes**: the SSH | SFTP switch beside the connection button (⌘1 / ⌘2) shows the server picked either as an SSH session or as its files, using the whole window. Each server keeps its own session running while you look at its files or at other servers.
- **Where the files start**: once a server is connected, SFTP's side for it opens at the server folder set in its connection settings (or else the folder last seen there); from then on the files and the SSH session each go their own way.
- **Built-in terminal**: an xterm-compatible terminal (xterm-256color), so vim, htop, top, less, tmux and the like work: 256 colors and true color, bold, underline, the alternate screen, mouse reporting, bracketed paste, wide Chinese characters, and typing with input methods (Zhuyin, Pinyin…) composing at the cursor. Scroll back through 10,000 lines with the trackpad or ⇧PageUp/⇧PageDown; drag to select (double-click a word, triple-click a line; ⌥-drag when a program has the mouse), ⌘C / ⌘V, ⌘K (or the eraser in the toolbar) clears the screen and the scrollback, as Terminal's does, ⌘+ / ⌘− / ⌘0 change the text size. ⌥ works as Meta (⌥B / ⌥F move by words) unless turned off in the Terminal menu. The session starts in the folder the files are showing, or the server's start folder, or the last one seen there.
- **Every start is a fresh one**: MenuSSH opens on this Mac's terminal with nothing connected, and closes the shared connections left from its last run.
- **This Mac's terminal when nothing is connected**: with no server chosen (This Mac, at the top of the connection menu), the terminal is a shell on this Mac: your login shell, starting in your home folder, as in Terminal. When it ends, Return starts another. SFTP needs a server, so it's off meanwhile.
- **Closing a connection**: when the SSH session ends (typing `exit`, or the connection dropping), or its tab is closed (× or ⌥⌘D), the server's shared connection is closed too, SFTP is switched off for it, and the window goes back to this Mac's terminal; choosing the server from the connection menu again reconnects it and brings SFTP back. The title the shell gives (user@host:folder) shows in the status line. Esc goes to the terminal here, not to hiding the window.
- **Two panes in SFTP mode: this Mac on the left, the server on the right**, each with its own folder bar, the side's name inside its path field: name, size, date modified (and permissions on the server), folders first, sortable by any column. Double-click a folder to go in, ⌘↑ for the enclosing folder, ⇧⌘H for home, or type a path and press Return. Both bars have buttons for choosing a folder and refreshing, the server's in mirror order (download, folder, refresh, then the path): on this Mac the folder button opens a folder panel, and on the server it drops down the folders above this one, the folders visited there lately, and Type a Path…. The left side follows changes made in the Finder. Hidden files (names starting with `.`) show with the eye button. Each server reopens in the folder you last left it in, and the left side where you left it. Columns that don't fit a narrow pane (permissions, then the date) step aside until there's room. Keyboard commands (⌘⌫, ⌘R, ⌘↑…) act on the side that has the focus; on this Mac, ⌘⌫ moves to the Trash.
- **Synchronized browsing**: the lock in the toolbar (⌥⌘Y) ties the two sides together: going into a folder, up, or anywhere else on one side makes the same move on the other, so a site's copy on this Mac and on the server can be walked side by side. If the other side has no matching folder, the lock comes off and the status line says why; it also comes off when you switch hosts.
- **Drag to transfer**: drag files and folders from the left to the right to upload them, or from the right to the left to download them, into the folder showing or onto a folder in the list. Files from the Finder can be dropped on the server's side too, and the server's files dragged out to the Finder or the desktop. The → arrow on this Mac's bar (⌘U) uploads what's selected on the left, or files chosen in a panel; the ← arrow on the server's bar (⌘D) downloads what's selected on the right into the folder on the left. Before anything with the same name is replaced you're asked: on the server, replace or skip; on this Mac, replace or keep both (the new one numbered “name 2”). “Download To…” asks where.
- **Transfer progress**: every file or folder is a row in the transfer list under the panes, which opens as transfers start (⌥⌘L or the arrows button in the footer shows or hides it): its direction, name and destination, a progress bar, and how much of the whole is done (percent, amount of the total, speed, time left; for a folder, the file under way too), then done (with its size and time), failed (with why) or cancelled. The total is worked out before it starts (a folder on this Mac is added up; one on the server is asked with `du`), so a folder's bar runs across all its files, not file by file. The footer shows the percent of everything under way. Each row has its own stop button, a failed or cancelled one can be tried again, and a finished download shown in the Finder. “Stop All” and “Clear Finished” at the top. The footer shows the transfer under way too, in SSH mode as well.
- **Open and edit in place**: double-click a file to open it in its app on your Mac. When you save it there, the change is uploaded back to the server.
- **Fast transfers in the background**: three at a time (each riding the server's one shared connection), with 255 KB blocks and 64 under way at once (sftp's defaults are 32 KB), so distant servers and folders of many files go quicker; the window stays usable meanwhile.
- **File and folder info** (right-click → File Info… / Folder Info…, or ⌘I), on this Mac or the server: kind, place, size (a folder's added up), dates, owner, and its name and permissions to change, with boxes for read, write and run (or the number, such as 755); a folder's permissions can go to everything in it too.
- **New folder, rename, delete, move**: ⇧⌘N, right-click → Rename…, ⌘⌫ (folders are deleted with what's in them, after asking), or drag items onto a folder in the list to move them there. ⌥⌘C copies the paths.
- **Passwords too, asked once**: servers using keys or ssh-agent just connect. For a password, key passphrase or a new server's host key, MenuSSH asks in a dialog of its own; a password can be remembered (encrypted with AES-GCM in `~/Library/Application Support/MenuSSH`, readable only by you). One shared connection per server (OpenSSH's ControlMaster) carries the browsing, the transfers, and the Terminal windows opened from MenuSSH, so you sign in once and every later step starts at once.
- Uses the Mac's own `ssh` and `sftp`, so everything in your SSH setup applies: keys, agents, ProxyJump, ports and the rest.
- **Pinning**: the pin turns the window into a floating one you can drag anywhere and resize; it stays up while you use other apps.
- **Show in the Dock, the menu bar, or both** (at least one stays on).
- **Traditional Chinese / Simplified Chinese / English UI**, light or dark theme, and an option to open at login.

| Shortcut | Action |
|---|---|
| ⌘1 / ⌘2 | SSH / SFTP mode |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⌥⌘D | Close the tab (end the connection) |
| ⇧⌘R | Reconnect the SSH session |
| ⌘K | Clear the screen and the scrollback |
| ⌘+ / ⌘− / ⌘0 | Terminal text size |
| Return / ⌘↓ | Open the selected folder or file |
| ⌘↑ / ⇧⌘H | Enclosing folder / home folder |
| ⇧⌘G | Type a path |
| ⌥⌘Y | Synchronized browsing on or off |
| ⇧⌘K | Connection settings |
| ⌘U / ⌘D / ⇧⌘D | Upload / download / download to… |
| ⌘I | File or folder info |
| ⌥⌘L | Show or hide the transfers |
| ⇧⌘N | New folder |
| ⌘⌫ | Delete |
| ⌘R | Refresh |
| ⇧⌘. | Show or hide hidden files |
| ⌘. | Stop transfers |
| Esc | Hide the window (or cancel what's running); in the terminal it goes to the program |

## Install

Requires macOS 13 or later, on Intel or Apple silicon. The server needs SFTP (standard with OpenSSH); deleting a folder uses `rm -rf` in the server's shell.

### Download

Paste this into Terminal to download the latest version, install it in Applications and open it:

```sh
curl -L https://github.com/janfon-source/MenuSSH/releases/latest/download/MenuSSH.zip -o /tmp/MenuSSH.zip && ditto -x -k /tmp/MenuSSH.zip /Applications && open /Applications/隨手SSH.app
```

Or download the zip from [Releases](https://github.com/janfon-source/MenuSSH/releases/latest), unzip it and move 隨手SSH to Applications. The app isn't notarized, so a browser download is blocked the first time: try to open it, click Done at the warning, then click Open Anyway in System Settings → Privacy & Security. The Terminal command above avoids this.

### Build from source

Requires Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/janfon-source/MenuSSH.git
cd MenuSSH
./build.sh install   # builds and installs /Applications/隨手SSH.app
```

Run `./build.sh` alone to build into `build/隨手SSH.app` without installing.

---

## 中文說明

住在 macOS 選單列的輕量 SSH / SFTP 工具。用左上角的連線按鈕（網路圖示）選一台 `~/.ssh/config` 裡的主機，就能在內建的終端機登入（SSH 模式），或瀏覽它的檔案、上傳和下載（SFTP 模式）。

### 功能

- **`~/.ssh/config` 就是主機清單**：按工具列左上角的連線按鈕（網路圖示）會列出設定檔裡每一個 Host（滑鼠停在上面會顯示實際連到哪裡，user@hostname:port）；已連線時圖示會變成強調色，滑鼠停在圖示上和狀態列都會顯示目前的主機，讀法和 ssh 相同（`Host *` 預設值、`Include` 檔案）；已連線的主機前面有綠點。在選單列圖示上按右鍵，不必先開視窗就能連到任何一台主機。同一個選單的「連線到其他主機…」可以連到不在設定檔裡的主機（`user@host` 或 `user@host:port`），之後也會留在選單裡。選單下方是目前主機可做的事：拷貝 ssh 指令、忘記儲存的密碼、關閉標籤頁。ssh、scp 等工具用的是同一個檔案，在這裡設定好的連線在那些工具裡也能用。
- **管理連線設定**（⇧⌘K，或連線選單）：列出 `~/.ssh/config` 及其 Include 檔案裡的每個 Host，可新增（＋）、複製、刪除，也可以拖曳調整順序：也就是在檔案裡的順序，連線選單會照這個順序排列（區塊連同上方的註解一起移動；把 `Host *` 移到其他主機上方時會提醒你，因為它的設定會蓋過下方主機的設定）。選取的那一個顯示在表單裡：名稱（一個或多個，也可以是 `*.example.com` 這樣的樣式）、主機位址（HostName）、帳號、連接埠、金鑰檔（有「選擇…」按鈕）、跳板主機（ProxyJump）、連線後的遠端資料夾（SSH 和 SFTP 都從這裡開始，例如 `/var/www` 或 `~/site`）、SFTP 本機資料夾（左側切到這裡，可搭配同步瀏覽），以及這個區塊的其他設定和註解（以文字原樣呈現）。按「儲存」才會寫入，並先檢查名稱空白、連接埠錯誤和名稱重複；只重寫有變動的區塊，註解、`Match` 區塊和檔案其他部分都保持原樣。兩個資料夾是隨手SSH 自己的設定，所以以註解的形式存在區塊裡（`# MenuSSH StartFolder /var/www`），ssh 和其他工具會略過。新的連線會放在 `Host *` 之前，免得被那裡的預設值蓋過。原檔會備份成同一資料夾的 `config.menussh-backup`；如果 config 是連結（例如指到 dotfiles 資料夾），存檔後仍是連結。其他需求可以按「用文字編輯器開啟…」。
- **標籤頁管理連線**：工具列下方的第一個標籤固定是「本機」，在最左邊、一直都在；從連線選單開啟的每台主機各有一個標籤，以連線名稱為標題。點標籤切換（⌃Tab／⌃⇧Tab 切到下一個、上一個），每個標籤各自保留 SSH 連線、SSH 或 SFTP 模式和遠端資料夾。拖曳主機的標籤可調整順序。按 × 關閉標籤就會中斷那條連線（目前的標籤也可按 ⌥⌘D）；連線自己結束（`exit` 或斷線）時標籤也會關閉。本機標籤不能關閉。
- **SSH 和 SFTP 兩種模式**：連線按鈕旁的 SSH | SFTP 切換（⌘1／⌘2），把選取的主機顯示成 SSH 連線或它的檔案，佔滿整個視窗。每台主機各有自己的連線，看檔案或切到別台主機時也會繼續執行。
- **檔案從哪裡開始**：主機連上後，SFTP 遠端那側會打開連線設定中的預設遠端資料夾（沒設定時打開上次看的資料夾）；之後檔案瀏覽和 SSH 連線各走各的，不會互相同步。
- **內建終端機**：相容 xterm（xterm-256color），vim、htop、top、less、tmux 等都能用：256 色和全彩、粗體、底線、替代畫面、滑鼠回報、括號貼上、中文全形字，以及用注音、拼音等輸入法在游標處組字。用觸控板或 ⇧PageUp／⇧PageDown 往回捲動 10,000 行；拖曳選取文字（按兩下選一個字、按三下選一行；程式使用滑鼠時按住 ⌥ 拖曳），⌘C／⌘V 拷貝貼上，⌘K（或工具列的橡皮擦）清除畫面和回捲紀錄，和「終端機」App 一樣，⌘+／⌘−／⌘0 調整字體大小。⌥ 鍵預設當 Meta 鍵（⌥B／⌥F 以字為單位移動），可在「終端機」選單關閉。連線會從目前檔案瀏覽的資料夾開始，沒有的話從這台主機設定的起始資料夾，再沒有就從上次所在的資料夾。
- **每次啟動都重新開始**：隨手SSH 啟動時一律從本機終端機開始、不連任何主機，並關閉上次留下的共用連線。
- **未連線時是本機終端機**：沒有選主機時（連線選單最上面的「本機（這台 Mac）」），終端機就是這台 Mac 的 shell：你的登入 shell，從家目錄開始，和「終端機」App 一樣。結束後按 Return 再開一個。SFTP 需要連上主機，這時會停用。
- **關閉連線**：SSH 連線結束時（輸入 `exit` 或連線中斷），或關閉它的標籤（× 或 ⌥⌘D），這台主機的共用連線也會關閉，SFTP 暫停使用，視窗回到本機終端機；從連線選單再選一次那台主機就會重新連線，SFTP 也隨之恢復。shell 給的標題（user@host:資料夾）顯示在狀態列。在終端機裡 Esc 會送給程式，不會隱藏視窗。
- **SFTP 左右分割：左邊本機、右邊遠端**，各有自己的路徑列，「本機」「遠端」字樣在路徑欄裡：名稱、大小、修改日期（遠端另有權限），資料夾排在前面，可依任一欄排序。按兩下資料夾進入，⌘↑ 回上一層，⇧⌘H 回家目錄，也可以輸入路徑後按 Return。兩側的路徑列都有選擇資料夾和重新整理按鈕，遠端那側左右相反（下載、前往資料夾、重新整理、路徑）：本機的資料夾按鈕開啟選擇面板，遠端的則列出目前路徑的各層上層資料夾、這台主機最近去過的資料夾，以及「輸入路徑…」。本機那側會跟著 Finder 裡的變動自動更新。眼睛按鈕顯示以 `.` 開頭的隱藏檔。每台主機都會回到上次看的資料夾，本機也是。窗格太窄時，放不下的欄位（先是權限，再來是日期）會暫時收起。鍵盤指令（⌘⌫、⌘R、⌘↑…）作用在目前有焦點的那一側；在本機那側 ⌘⌫ 是移到垃圾桶。
- **同步瀏覽**：工具列的鎖頭（⌥⌘Y）把兩側鎖在一起：在一側進入資料夾、回上一層或跳到別處，另一側會做同樣的移動，方便對照本機和伺服器上的同一份網站。另一側沒有對應的資料夾時會自動解除，並在狀態列說明原因；換主機時也會解除。
- **拖曳傳輸**：把檔案或資料夾從左邊拖到右邊就上傳，從右邊拖到左邊就下載，放到目前的資料夾或清單中的某個資料夾上都可以。也可以從 Finder 拖到遠端那側，或把遠端的檔案拖到 Finder 或桌面。本機路徑列的 → 箭頭（⌘U）上傳左邊選取的項目（沒有選取時用對話框選檔案）；遠端路徑列的 ← 箭頭（⌘D）把右邊選取的項目下載到左邊的資料夾。遇到同名項目會先詢問：上傳時可取代或略過；下載時可取代或兩者都保留（新的命名為「名稱 2」）。「下載到…」會詢問位置。
- **監看傳輸進度**：每個檔案或資料夾在下方的傳輸清單裡各佔一列，開始傳輸時清單會自動打開（⌥⌘L 或狀態列的箭頭按鈕可顯示或收起）：方向、名稱、目的地、進度條，以及整體完成的程度（百分比、已傳量／總量、速度、剩餘時間；資料夾另外顯示正在傳的檔案），結束後顯示完成（大小與耗時）、失敗（原因）或已取消。開始前會先算出總大小（本機資料夾直接加總，伺服器上的資料夾用 `du` 查詢），所以資料夾的進度條是依全部檔案計算，而不是一個檔案一個檔案重來。下方狀態列顯示所有進行中傳輸的整體百分比。每一列都能單獨停止；失敗或取消的可以再試一次；下載完成的可以在 Finder 中顯示。上方有「全部停止」和「清除已完成」。狀態列也會顯示進行中的傳輸，SSH 模式下也看得到。
- **直接開啟、編輯**：按兩下檔案，就用 Mac 上對應的 App 開啟；在那裡儲存後，修改會自動上傳回伺服器。
- **快速的背景傳輸**：同時進行 3 個（共用這台主機的同一條連線），每次傳 255 KB、同時 64 個請求（sftp 預設是 32 KB），連遠端伺服器或傳很多小檔案時都比較快；傳輸時視窗照常可用。
- **檔案與資料夾資訊**（右鍵 →「檔案資訊…」／「資料夾資訊…」，或 ⌘I），本機和遠端都可以：種類、位置、大小（資料夾會加總）、日期、擁有者，並可修改名稱和權限：用讀、寫、執行的勾選格（或直接輸入數字，例如 755）；資料夾的權限也可以套用到裡面所有項目。
- **新增資料夾、重新命名、刪除、搬移**：⇧⌘N、右鍵 →「重新命名…」、⌘⌫（資料夾會連同內容刪除，會先確認），或把項目拖到清單中的資料夾上搬過去。⌥⌘C 拷貝路徑。
- **密碼登入也只問一次**：用金鑰或 ssh-agent 的主機直接連線。需要密碼、金鑰密語或第一次連線確認主機金鑰時，隨手SSH 會跳出自己的對話框；密碼可以選擇記住（以 AES-GCM 加密存在 `~/Library/Application Support/MenuSSH`，只有你的帳號能讀取）。每台主機共用一條連線（OpenSSH 的 ControlMaster），瀏覽、傳輸以及從隨手SSH 開啟的終端機視窗都走這條連線，所以只要登入一次，之後每個動作都立即開始。
- 使用 Mac 內建的 `ssh` 和 `sftp`，SSH 的各種設定都適用：金鑰、agent、ProxyJump、連接埠等等。
- **釘選**：按圖釘把視窗變成可拖曳到任何位置、可調整大小的浮動視窗，切換到其他 App 時也不會消失。
- **可選擇顯示在 Dock、選單列或兩者**（至少保留一個）。
- **繁體中文／簡體中文／英文介面**、淺色或深色主題，以及登入時自動開啟。

| 快速鍵 | 功能 |
|---|---|
| ⌘1 / ⌘2 | SSH／SFTP 模式 |
| ⌃Tab / ⌃⇧Tab | 下一個／上一個標籤頁 |
| ⌥⌘D | 關閉標籤頁（中斷連線） |
| ⇧⌘R | 重新連線 |
| ⌘K | 清除畫面和回捲紀錄 |
| ⌘+ / ⌘− / ⌘0 | 終端機字體大小 |
| Return / ⌘↓ | 開啟選取的資料夾或檔案 |
| ⌘↑ / ⇧⌘H | 上一層資料夾／家目錄 |
| ⇧⌘G | 輸入路徑 |
| ⌥⌘Y | 開啟或解除同步瀏覽 |
| ⇧⌘K | 管理連線設定 |
| ⌘U / ⌘D / ⇧⌘D | 上傳／下載／下載到… |
| ⌘I | 檔案或資料夾資訊 |
| ⌥⌘L | 顯示或收起傳輸清單 |
| ⇧⌘N | 新增資料夾 |
| ⌘⌫ | 刪除 |
| ⌘R | 重新整理 |
| ⇧⌘. | 顯示或隱藏隱藏檔 |
| ⌘. | 停止傳輸 |
| Esc | 隱藏視窗（或取消進行中的動作）；在終端機裡則送給程式 |

### 安裝

需要 macOS 13 以上，Intel 或 Apple 晶片皆可。伺服器需要支援 SFTP（OpenSSH 預設就有）；刪除資料夾時會在伺服器的 shell 執行 `rm -rf`。

#### 下載

把下面這行貼到終端機，就會下載最新版、安裝到「應用程式」並開啟：

```sh
curl -L https://github.com/janfon-source/MenuSSH/releases/latest/download/MenuSSH.zip -o /tmp/MenuSSH.zip && ditto -x -k /tmp/MenuSSH.zip /Applications && open /Applications/隨手SSH.app
```

也可以從 [Releases](https://github.com/janfon-source/MenuSSH/releases/latest) 下載 zip，解壓縮後把隨手SSH 移到「應用程式」。這個 App 沒有經過公證，用瀏覽器下載的第一次開啟會被擋下：先嘗試開啟，在警告上按「完成」，再到「系統設定」→「隱私權與安全性」按「強制打開」。用上面的終端機指令安裝則不會遇到。

#### 自行建置

需要 Xcode 或 Command Line Tools（`xcode-select --install`）。

```sh
git clone https://github.com/janfon-source/MenuSSH.git
cd MenuSSH
./build.sh install   # 建置並安裝 /Applications/隨手SSH.app
```

只執行 `./build.sh` 則建置到 `build/隨手SSH.app`，不安裝。
