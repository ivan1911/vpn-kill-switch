import AppKit

private final class DestinationRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard let field = (view(atColumn: 0) as? NSTableCellView)?.textField else { return }
        let highlight = convert(field.bounds, from: field).insetBy(dx: -2, dy: -1)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: highlight, xRadius: 3, yRadius: 3).addClip()
        super.drawSelection(in: dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class DestinationField: NSTextField {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        let text = currentEditor()?.string ?? stringValue
        size.width = ceil((text as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width) + 8
        return size
    }
}

private final class DestinationTable: NSTableView {
    override func mouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        let modifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        guard isEnabled, index >= 0, event.clickCount == 1,
              event.modifierFlags.intersection(modifiers).isEmpty,
              let field = (view(atColumn: 0, row: index, makeIfNecessary: true) as? NSTableCellView)?.textField,
              let window else {
            super.mouseDown(with: event)
            return
        }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        field.selectText(nil)
        if field.currentEditor() == nil { window.makeFirstResponder(field) }
    }
}

final class ExceptionsView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let allIPv4Destination = "0.0.0.0/0"

    var onApply: ((_ previous: String, _ next: String) -> Void)?

    var onReadProtected: ((_ completion: @escaping (Admin.Result) -> Void) -> Void)?
    private let table = DestinationTable()
    private let emptyMessage = NSTextField(wrappingLabelWithString: "No exceptions. Localhost is always allowed.")
    private let add = NSButton()
    private let remove = NSButton()
    private let entry = NSTextField()
    private let reload = NSButton()
    private var needsProtectedRead = false
    private var needsReadRetry = false
    private var needsConflictReload = false
    private var feedbackTrailing: NSLayoutConstraint?
    private var feedbackTrailingWithReload: NSLayoutConstraint?
    let apply = NSButton(title: "Apply", target: nil, action: nil)
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let read: () throws -> String
    private let validate: (String) throws -> String
    // Every checker process runs here, never on the main thread.
    private let work = DispatchQueue(label: "vpn-ks.exceptions.check", qos: .userInitiated)
    private var saved: [String]?
    private var rows: [String] = []
    private var busy = false
    private var confirmingAllIPv4 = false
    private var operationBlocked: Bool { busy || confirmingAllIPv4 }
    // Reads and validations in flight. Their results arrive on the main queue.
    private var working = 0
    // Bumped by anything that can invalidate a pending result: typing, reload, add, remove.
    private var generation = 0
    private var applyWhenIdle = false
    var isChecking: Bool { working > 0 }
    private var originalRowText: String?

    private struct ReadError: Error {
        let exitCode: Int
        let message: String
    }

    // Use the same parser as the privileged service when previewing an entry.
    // This waits for the process, so call it only from the background `work` queue.
    private static func check(_ arguments: [String], script: String = Commands.check) throws -> String {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "vpn-ks"] + arguments
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard task.terminationStatus == 0 else {
            throw ReadError(exitCode: Int(task.terminationStatus), message: message)
        }
        return message
    }

    init(read: (() throws -> String)? = nil, validate: ((String) throws -> String)? = nil) {
        self.read = read ?? { try Self.check(["--list-direct"]) }
        self.validate = validate ?? {
            try Self.check([$0], script: "printf '%s\\n' \"$1\" | /bin/sh -c " + Admin.quote(Commands.check) + " _ --validate-direct -")
        }
        super.init(frame: .zero)
        let hint = NSTextField(wrappingLabelWithString: "These destinations bypass the VPN, even when disconnected. Localhost is always allowed.")
        hint.textColor = .secondaryLabelColor
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("destination"))
        column.isEditable = true
        column.title = "IPv4 address or network"
        table.style = .plain
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Direct IPv4 destinations")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        entry.isBezeled = false
        entry.isBordered = false
        entry.drawsBackground = false
        entry.placeholderString = "IPv4, CIDR or 192.168.*"
        entry.setAccessibilityLabel("New exception")
        entry.delegate = self
        entry.target = self
        entry.action = #selector(addEntry)
        (entry.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        for (button, symbol, description, action) in [
            (add, "plus", "Add exception", #selector(addEntry)),
            (remove, "minus", "Remove selected exceptions", #selector(removeSelection))
        ] {
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            button.imagePosition = .imageOnly
            button.toolTip = description
            button.setAccessibilityLabel(description)
            button.target = self
            button.action = action
            button.widthAnchor.constraint(equalToConstant: 29).isActive = true
        }
        let frame = NSBox()
        frame.boxType = .custom
        frame.cornerRadius = 0
        frame.borderWidth = 1
        frame.borderColor = .separatorColor
        frame.fillColor = .textBackgroundColor
        frame.contentViewMargins = .zero
        let inside = frame.contentView!
        let rule = NSBox()
        rule.boxType = .separator
        let entryDivider = NSBox()
        let buttonDivider = NSBox()
        for divider in [entryDivider, buttonDivider] {
            divider.boxType = .separator
            divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        }
        let footer = NSView()
        let entryLabel = NSTextField(labelWithString: "New exception")
        entryLabel.textColor = .secondaryLabelColor
        entryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [entryLabel, entry, entryDivider, add, buttonDivider, remove] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
        }
        emptyMessage.textColor = .secondaryLabelColor
        emptyMessage.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, rule, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            inside.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: inside.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: inside.trailingAnchor)
            ])
        }
        inside.addSubview(emptyMessage, positioned: .above, relativeTo: scroll)
        for view in [entryDivider, add, buttonDivider, remove] as [NSView] {
            view.topAnchor.constraint(equalTo: footer.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: footer.bottomAnchor).isActive = true
        }
        reload.target = self
        reload.action = #selector(reloadList)
        apply.target = self
        apply.action = #selector(submit)
        feedback.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        feedback.maximumNumberOfLines = 3
        feedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [hint, frame, feedback, reload, apply] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        feedbackTrailing = feedback.trailingAnchor.constraint(equalTo: apply.leadingAnchor, constant: -10)
        feedbackTrailingWithReload = feedback.trailingAnchor.constraint(equalTo: reload.leadingAnchor, constant: -10)
        SettingsWindow.positionActionButton(apply, in: self)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: apply.trailingAnchor),
            hint.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            frame.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            frame.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            frame.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: inside.topAnchor),
            emptyMessage.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 42),
            emptyMessage.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 10),
            emptyMessage.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -10),
            rule.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            entryLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: floor(table.intercellSpacing.width / 2) + 2),
            entryLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            entry.leadingAnchor.constraint(equalTo: entryLabel.trailingAnchor, constant: 8),
            entry.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            entryDivider.leadingAnchor.constraint(equalTo: entry.trailingAnchor, constant: 4),
            add.leadingAnchor.constraint(equalTo: entryDivider.trailingAnchor),
            buttonDivider.leadingAnchor.constraint(equalTo: add.trailingAnchor),
            remove.leadingAnchor.constraint(equalTo: buttonDivider.trailingAnchor),
            remove.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footer.topAnchor.constraint(equalTo: rule.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: table.rowHeight + table.intercellSpacing.height),
            footer.bottomAnchor.constraint(equalTo: inside.bottomAnchor),
            reload.trailingAnchor.constraint(equalTo: apply.leadingAnchor, constant: -8),
            reload.centerYAnchor.constraint(equalTo: apply.centerYAnchor),
            apply.topAnchor.constraint(equalTo: frame.bottomAnchor, constant: 16),
            feedback.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            feedback.centerYAnchor.constraint(equalTo: apply.centerYAnchor),
            feedback.topAnchor.constraint(greaterThanOrEqualTo: frame.bottomAnchor, constant: 2)
        ])
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("destinationRow")
        if let view = tableView.makeView(withIdentifier: id, owner: self) as? DestinationRow { return view }
        let view = DestinationRow()
        view.identifier = id
        return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell.textField?.stringValue = rows[row]
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = DestinationField(labelWithString: rows[row])
        label.isEditable = true
        label.isSelectable = true
        label.delegate = self
        label.focusRingType = .none
        label.setAccessibilityLabel("Exception address")
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        !operationBlocked && working == 0 && saved != nil
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== entry else { return }
        let row = table.row(for: field)
        if rows.indices.contains(row) { originalRowText = rows[row] }
    }

    func controlTextDidChange(_ notification: Notification) {
        generation += 1
        if let field = notification.object as? NSTextField, field !== entry {
            let row = table.row(for: field)
            if rows.indices.contains(row) {
                rows[row] = field.stringValue
                field.invalidateIntrinsicContentSize()
                table.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
            }
        }
        updateControls()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field !== entry else { return }
        defer { originalRowText = nil }
        let row = table.row(for: field)
        if rows.indices.contains(row), let original = originalRowText, rows[row] != original {
            let raw = rows[row]
            validated(raw, replacing: row) { [weak self] value in
                guard let self, self.rows.indices.contains(row), self.rows[row] == raw else { return }
                self.rows[row] = value
                self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            }
        }
        updateControls()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NSTextField, field !== entry else { return false }
        let row = table.row(for: field)
        guard rows.indices.contains(row) else { return false }
        func commit(_ value: String) {
            textView.string = value
            field.stringValue = value
            rows[row] = value
            originalRowText = value
            window?.makeFirstResponder(table)
            updateControls()
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let raw = textView.string
            validated(raw, replacing: row) { [weak self] value in
                guard let self, self.rows.indices.contains(row), self.rows[row] == raw else { return }
                commit(value)
            }
        case #selector(NSResponder.cancelOperation(_:)):
            generation += 1
            message("")
            commit(originalRowText ?? rows[row])
        default:
            return false
        }
        return true
    }

    private func endRowEditing() {
        if originalRowText != nil { window?.makeFirstResponder(table) }
    }

    private var input: String { entry.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    func refreshIfClean() {
        if !operationBlocked && working == 0 && originalRowText == nil && (saved == nil || (saved == rows && input.isEmpty)) { loadList(authorize: false) }
    }
    func setBusy(_ value: Bool) {
        if value { endRowEditing() }
        busy = value
        updateControls()
    }

    private func updateControls() {
        let editing = !operationBlocked && working == 0 && saved != nil
        emptyMessage.isHidden = saved == nil || !rows.isEmpty
        table.isEnabled = editing
        entry.isEnabled = editing
        add.isEnabled = editing && !input.isEmpty
        remove.isEnabled = editing && table.numberOfSelectedRows > 0
        apply.isEnabled = editing && (rows != saved || !input.isEmpty)
        reload.isHidden = !needsProtectedRead && !needsReadRetry && !needsConflictReload
        reload.title = needsProtectedRead ? "Read with Administrator Access…" : "Reload"
        reload.isEnabled = !operationBlocked && working == 0
        if reload.isHidden {
            feedbackTrailingWithReload?.isActive = false
            feedbackTrailing?.isActive = true
        } else {
            feedbackTrailing?.isActive = false
            feedbackTrailingWithReload?.isActive = true
        }
    }

    @objc private func reloadList() { loadList(authorize: needsProtectedRead) }

    private func loadList(authorize: Bool) {
        guard !operationBlocked, working == 0 else { return }
        working += 1
        updateControls()
        let read = self.read
        work.async { [weak self] in
            let result = Result { try read() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.working -= 1
                switch result {
                case .success(let list): self.showList(list)
                case .failure(let error): self.readFailed(error, authorize: authorize)
                }
            }
        }
    }

    private func readFailed(_ error: Error, authorize: Bool) {
        let failure = error as? ReadError
        needsProtectedRead = failure?.exitCode == 77 || (error as? CocoaError)?.code == .fileReadNoPermission
        needsReadRetry = !needsProtectedRead
        updateControls()
        if !needsProtectedRead {
            message(failure.flatMap { Admin.exceptionReadExplanation($0.message) }
                    ?? "Could not read saved exceptions. Check the file and click Reload.", error: true)
        } else if authorize, let onReadProtected {
            setBusy(true)
            onReadProtected { [weak self] result in
                guard let self else { return }
                self.setBusy(false)
                if result.ok {
                    self.showList(result.message)
                } else if result.cancelled {
                    self.message("Read canceled.")
                } else if let explanation = Admin.exceptionReadExplanation(result.message) {
                    self.needsProtectedRead = false
                    self.needsReadRetry = true
                    self.updateControls()
                    self.message(explanation, error: true)
                } else {
                    self.message("Could not read exceptions.", error: true)
                }
            }
        } else {
            message("Administrator access is needed to read exceptions.", error: true)
        }
    }

    private func showList(_ result: String) {
        generation += 1
        endRowEditing()
        rows = result.split(separator: "\n").map(String.init)
        saved = rows
        needsProtectedRead = false
        needsReadRetry = false
        needsConflictReload = false
        entry.stringValue = ""
        table.reloadData()
        message("")
        updateControls()
    }

    /// Checks an entry on the background queue. `accepted` runs on the main queue with the
    /// normalized value; `rejected` runs when the entry is refused. Neither runs when the
    /// input changed while the check was running.
    private func validated(_ raw: String, replacing row: Int? = nil, rejected: (() -> Void)? = nil,
                           accepted: @escaping (String) -> Void) {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.range(of: #"\A[0-9a-z.:*/]+\z"#, options: .regularExpression) != nil else {
            message("Enter an IPv4 address, an aligned CIDR or a trailing wildcard.", error: true)
            rejected?()
            return
        }
        let token = generation
        working += 1
        updateControls()
        let check = validate
        work.async { [weak self] in
            let result = Result { try check(input) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.working -= 1
                self.updateControls()
                defer { self.resumeApply() }
                guard token == self.generation else { return }
                guard case .success(let value) = result else {
                    self.message("Enter an IPv4 address, an aligned CIDR or a trailing wildcard.", error: true)
                    rejected?()
                    return
                }
                guard !value.isEmpty else { self.message("Loopback is already allowed."); rejected?(); return }
                guard !self.rows.indices.contains(where: { $0 != row && self.rows[$0] == value }) else {
                    self.message("This destination is already listed.")
                    rejected?()
                    return
                }
                self.message(value == Self.allIPv4Destination ? "This allows all IPv4 traffic outside the VPN." : "")
                accepted(value)
            }
        }
    }

    private func appendInput(then next: (() -> Void)? = nil) {
        endRowEditing()
        let raw = input
        validated(raw) { [weak self] value in
            guard let self, self.input == raw else { return }
            self.generation += 1
            self.rows.append(value)
            self.table.reloadData()
            self.table.selectRowIndexes(IndexSet(integer: self.rows.count - 1), byExtendingSelection: false)
            self.table.scrollRowToVisible(self.rows.count - 1)
            self.entry.stringValue = ""
            self.updateControls()
            next?()
        }
    }

    @objc private func addEntry() {
        guard !operationBlocked, working == 0, saved != nil else { return }
        appendInput()
    }

    @objc private func removeSelection() {
        guard !operationBlocked, working == 0, saved != nil else { return }
        endRowEditing()
        generation += 1
        for i in table.selectedRowIndexes.reversed() { rows.remove(at: i) }
        table.reloadData()
        message("")
        updateControls()
    }

    @objc private func submit() {
        guard !operationBlocked, saved != nil, onApply != nil else { return }
        endRowEditing()
        // Leaving a row editor starts its own check. Apply continues once it finishes.
        if working > 0 { applyWhenIdle = true; return }
        if input.isEmpty { validateChangedRows() } else { appendInput { [weak self] in self?.validateChangedRows() } }
    }

    private func resumeApply() {
        guard applyWhenIdle, working == 0 else { return }
        applyWhenIdle = false
        submit()
    }

    // Focus can leave an invalid draft visible for correction. Never send a
    // partial list or silently collapse duplicate destinations on Apply.
    private func validateChangedRows(from start: Int = 0) {
        guard let saved, saved != rows, let onApply else { return }
        guard let row = rows.indices.dropFirst(start).first(where: { !saved.contains(rows[$0]) }) else {
            guard Set(rows).count == rows.count else {
                message("This destination is already listed.")
                return
            }
            if rows.contains(Self.allIPv4Destination) {
                confirmAllIPv4 { [weak self] in self?.applyRows(saved: saved, using: onApply) }
            } else {
                applyRows(saved: saved, using: onApply)
            }
            return
        }
        let raw = rows[row]
        validated(raw, replacing: row, rejected: { [weak self] in
            guard let self, self.rows.indices.contains(row) else { return }
            self.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            self.table.scrollRowToVisible(row)
            (self.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.selectText(nil)
        }, accepted: { [weak self] value in
            guard let self, self.rows.indices.contains(row), self.rows[row] == raw else { return }
            self.rows[row] = value
            self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            self.validateChangedRows(from: row + 1)
        })
    }

    private func confirmAllIPv4(confirmed: @escaping () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        alert.messageText = "Allow all IPv4 traffic outside the VPN?"
        alert.informativeText = "The 0.0.0.0/0 exception lets all IPv4 traffic bypass the VPN, even when disconnected."
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Allow All IPv4").keyEquivalent = ""
        confirmingAllIPv4 = true
        updateControls()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.confirmingAllIPv4 = false
            if response == .alertSecondButtonReturn && !self.busy { confirmed() }
            else { self.updateControls() }
        }
    }

    private func applyRows(saved: [String], using onApply: (String, String) -> Void) {
        setBusy(true)
        message("Applying…")
        onApply(saved.joined(separator: "\n"), rows.joined(separator: "\n"))
    }

    func finish(_ result: Admin.Result) {
        let conflict = Admin.Failure(.exceptions, result: result)?.requiresReload == true
        if result.ok {
            saved = rows
            needsConflictReload = false
        } else if conflict {
            needsConflictReload = true
        }
        let lastLine = result.message.split(separator: "\n").last.map(String.init)
        setBusy(false)
        if result.ok {
            message(lastLine ?? "Exceptions applied.")
        } else if result.cancelled {
            message("Changes canceled.")
        } else {
            message(conflict ? "Saved exceptions changed. Click Reload." : "Could not apply exceptions.", error: true)
        }
    }

    private func message(_ text: String, error: Bool = false) {
        feedback.textColor = error ? .systemRed : .secondaryLabelColor
        feedback.stringValue = text
    }
}
