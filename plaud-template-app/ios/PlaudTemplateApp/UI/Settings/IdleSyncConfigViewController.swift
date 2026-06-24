import UIKit
import Combine

/// Configures the device-side "Sync when idle" feature: a master enable toggle
/// plus the list of WiFi networks the device may use to auto-upload recordings
/// while idle/charging. Each network can be connectivity-tested.
final class IdleSyncConfigViewController: UIViewController {

    private let syncManager: SyncManagerProtocol
    private var cancellables = Set<AnyCancellable>()
    private var state = IdleSyncState()

    // MARK: Views

    private let enableCard = UIView()
    private let enableToggle = PlaudToggle()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private lazy var addButton: UIButton = {
        let btn = PlaudTheme.makePrimaryButton(title: "Add Network")
        btn.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        return btn
    }()

    // MARK: Init

    init(syncManager: SyncManagerProtocol = SyncManager.shared) {
        self.syncManager = syncManager
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sync When Idle"
        view.backgroundColor = PlaudTheme.backgroundPrimary
        setupLayout()
        setupBindings()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        syncManager.loadIdleSyncConfig()
    }

    // MARK: Layout

    private func setupLayout() {
        enableCard.backgroundColor = .white
        enableCard.layer.cornerRadius = 12
        enableCard.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = UILabel()
        titleLbl.text = "Auto-upload over WiFi"
        titleLbl.font = .systemFont(ofSize: 14)
        titleLbl.textColor = .black
        titleLbl.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLbl = UILabel()
        subtitleLbl.text = "Device syncs recordings while idle or charging"
        subtitleLbl.font = .systemFont(ofSize: 13)
        subtitleLbl.textColor = UIColor(hex: "#7A7A7A")
        subtitleLbl.numberOfLines = 0
        subtitleLbl.translatesAutoresizingMaskIntoConstraints = false

        enableToggle.translatesAutoresizingMaskIntoConstraints = false
        enableToggle.onToggle = { [weak self] isOn in
            self?.syncManager.setIdleSyncEnabled(isOn)
        }

        [titleLbl, subtitleLbl, enableToggle].forEach { enableCard.addSubview($0) }

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(IdleSyncNetworkCell.self, forCellReuseIdentifier: IdleSyncNetworkCell.reuseID)

        [enableCard, tableView, addButton].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            enableCard.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            enableCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            enableCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            titleLbl.topAnchor.constraint(equalTo: enableCard.topAnchor, constant: 16),
            titleLbl.leadingAnchor.constraint(equalTo: enableCard.leadingAnchor, constant: 16),

            subtitleLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),
            subtitleLbl.leadingAnchor.constraint(equalTo: enableCard.leadingAnchor, constant: 16),
            subtitleLbl.trailingAnchor.constraint(equalTo: enableToggle.leadingAnchor, constant: -12),
            subtitleLbl.bottomAnchor.constraint(equalTo: enableCard.bottomAnchor, constant: -16),

            enableToggle.centerYAnchor.constraint(equalTo: enableCard.centerYAnchor),
            enableToggle.trailingAnchor.constraint(equalTo: enableCard.trailingAnchor, constant: -16),
            enableToggle.widthAnchor.constraint(equalToConstant: 48),
            enableToggle.heightAnchor.constraint(equalToConstant: 26),

            tableView.topAnchor.constraint(equalTo: enableCard.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12),

            addButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            addButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            addButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            addButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    // MARK: Bindings

    private func setupBindings() {
        syncManager.idleSyncStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                let prev = self.state
                self.state = state
                if self.enableToggle.isOn != state.enabled {
                    self.enableToggle.isOn = state.enabled
                }
                self.tableView.reloadData()
                if let err = state.lastError, err != prev.lastError {
                    self.presentError(err)
                }
            }
            .store(in: &cancellables)
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: Actions

    @objc private func addTapped() {
        let alert = UIAlertController(title: "Add WiFi Network",
                                      message: "The device will use this network to sync while idle.",
                                      preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "SSID"; $0.autocapitalizationType = .none }
        alert.addTextField { $0.placeholder = "Password"; $0.isSecureTextEntry = true }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let ssid = alert?.textFields?.first?.text, !ssid.isEmpty else { return }
            let password = alert?.textFields?.last?.text ?? ""
            self?.syncManager.addIdleSyncNetwork(ssid: ssid, password: password)
        })
        present(alert, animated: true)
    }
}

// MARK: - UITableViewDataSource / Delegate

extension IdleSyncConfigViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Configured Networks"
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        state.networks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: IdleSyncNetworkCell.reuseID, for: indexPath) as! IdleSyncNetworkCell
        let network = state.networks[indexPath.row]
        cell.configure(network) { [weak self] in
            self?.syncManager.testIdleSyncNetwork(index: network.index)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let network = state.networks[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            self?.syncManager.deleteIdleSyncNetwork(index: network.index)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

// MARK: - Cell

private final class IdleSyncNetworkCell: UITableViewCell {

    static let reuseID = "IdleSyncNetworkCell"

    private let ssidLabel = UILabel()
    private let statusLabel = UILabel()
    private let testButton = UIButton(type: .system)
    private var onTest: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none

        ssidLabel.font = .systemFont(ofSize: 15)
        ssidLabel.textColor = .black
        ssidLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        testButton.setTitle("Test", for: .normal)
        testButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        testButton.translatesAutoresizingMaskIntoConstraints = false
        testButton.addTarget(self, action: #selector(testTapped), for: .touchUpInside)

        [ssidLabel, statusLabel, testButton].forEach { contentView.addSubview($0) }

        NSLayoutConstraint.activate([
            ssidLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            ssidLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.topAnchor.constraint(equalTo: ssidLabel.bottomAnchor, constant: 2),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            testButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            testButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ network: IdleSyncNetwork, onTest: @escaping () -> Void) {
        self.onTest = onTest
        ssidLabel.text = network.ssid
        switch network.testStatus {
        case .untested:
            statusLabel.text = "Not tested"
            statusLabel.textColor = UIColor(hex: "#7A7A7A")
            setTestEnabled(true)
        case .testing:
            statusLabel.text = "Testing…"
            statusLabel.textColor = UIColor(hex: "#7A7A7A")
            setTestEnabled(false)
        case .passed:
            statusLabel.text = "✓ Reachable"
            statusLabel.textColor = UIColor(hex: "#1E9E5A")
            setTestEnabled(true)
        case .failed:
            statusLabel.text = "✗ Unreachable"
            statusLabel.textColor = UIColor(hex: "#D14343")
            setTestEnabled(true)
        }
    }

    private func setTestEnabled(_ enabled: Bool) {
        testButton.isEnabled = enabled
        testButton.setTitleColor(enabled ? .black : UIColor(hex: "#B0B0B0"), for: .normal)
    }

    @objc private func testTapped() { onTest?() }
}
