/**
       This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
       Copyright © Adguard Software Limited. All rights reserved.
 
       Adguard for iOS is free software: you can redistribute it and/or modify
       it under the terms of the GNU General Public License as published by
       the Free Software Foundation, either version 3 of the License, or
       (at your option) any later version.
 
       Adguard for iOS is distributed in the hope that it will be useful,
       but WITHOUT ANY WARRANTY; without even the implied warranty of
       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
       GNU General Public License for more details.
 
       You should have received a copy of the GNU General Public License
       along with Adguard for iOS.  If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation
import UIKit

class GroupsController: UITableViewController {
    
    let enabledColor = UIColor.init(hexString: "67B279")
    let disabledColor = UIColor.init(hexString: "D8D8D8")
    
    let filtersSegueID = "showFiltersSegue"
    let customFiltersSegueID = "showCustomFiltersSegue"
    let getProSegueID = "getProSegue"
    
    // MARK: - properties
    var viewModel: FiltersAndGroupsViewModelProtocol? = nil
    var selectedIndex: Int?
    
    lazy var theme: ThemeServiceProtocol = { ServiceLocator.shared.getService()! }()
    
    let contentBlockerService: ContentBlockerService = ServiceLocator.shared.getService()!
    let aeService: AEServiceProtocol = ServiceLocator.shared.getService()!
    let filtersService: FiltersServiceProtocol = ServiceLocator.shared.getService()!
    let configuration: ConfigurationService = ServiceLocator.shared.getService()!
    
    // MARK: - lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name( ConfigurationService.themeChangeNotification), object: nil, queue: OperationQueue.main) {[weak self] (notification) in
            self?.updateTheme()
        }
        
        viewModel?.load() {[weak self] () in
            self?.tableView.reloadData()
        }
        
        viewModel?.bind { [weak self] (Int) in
            self?.tableView.reloadData()
        }
        
        setupBackButton()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel?.updateAllGroups()
        viewModel?.cancelSearch()
        updateTheme()
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        
        guard let selectedGroup = viewModel?.groups?[selectedIndex ?? 0] else { return }
        viewModel?.currentGroup = selectedGroup
        
        if segue.identifier == filtersSegueID {
            let controller = segue.destination as! FiltersController
            controller.viewModel = viewModel
        }
    }
    
    // MARK: - table view
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel?.groups?.count ?? 0
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let group = viewModel?.groups?[indexPath.row] else { return UITableViewCell() }
        let cell = tableView.dequeueReusableCell(withIdentifier: "groupCell") as! GroupCell
        
        cell.nameLabel.text = group.name
        cell.descriptionLabel.text = group.subtitle
        
        cell.enabledSwitch.isOn = group.enabled
        
        cell.enabledSwitch.tag = indexPath.row
        cell.enabledSwitch.removeTarget(self, action: nil, for: .valueChanged)
        cell.enabledSwitch.addTarget(self, action: #selector(GroupsController.enabledChanged(_:)), for: .valueChanged)
        
        var trailingConstraint: CGFloat = 0
        if group.proOnly && !configuration.proStatus {
            cell.enabledSwitch.isHidden = true
            cell.getPremiumButton.isHidden = false
            cell.icon.image = UIImage(named: group.disabledIconName ?? (group.iconName ?? ""))
            trailingConstraint = cell.getPremiumButton.frame.width + 10
        }else {
            cell.enabledSwitch.isHidden = false
            cell.getPremiumButton.isHidden = true
            cell.icon.image = UIImage(named: group.iconName ?? "")
            trailingConstraint = cell.enabledSwitch.frame.width + 10
        }
        
        cell.descriptionTrailingConstraint.constant = trailingConstraint
        cell.nameTrailingConstraint.constant = trailingConstraint

        theme.setupLabels(cell.themableLabels)
        theme.setupTableCell(cell)
        theme.setupSwitch(cell.enabledSwitch)
        
        return cell
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedIndex = indexPath.row
        guard let group = viewModel?.groups![selectedIndex!] else { return }
        if group.proOnly && !configuration.proStatus {
            performSegue(withIdentifier: getProSegueID, sender: self)
        }
        performSegue(withIdentifier: "showFiltersSegue", sender: self)
    }
    
    @IBAction func switchTap(_ sender: UIView) {
        for subview in (sender.superview?.subviews)! {
            if subview.isKind(of: UISwitch.self) {
                let enableSwitch = subview as! UISwitch
                enableSwitch.setOn(!enableSwitch.isOn, animated: true)
                enabledChanged(enableSwitch)
            }
        }
    }
    
    // MARK: - private methods
    
    @objc func enabledChanged(_ enableSwitch: UISwitch) {
        let row = enableSwitch.tag
        guard let group = viewModel?.groups?[row] else { return }
            viewModel?.set(group: group, enabled: enableSwitch.isOn)
    }
    
    private func updateTheme() {
        view.backgroundColor = theme.backgroundColor
        theme.setupNavigationBar(navigationController?.navigationBar)
        theme.setupTable(tableView)
        DispatchQueue.main.async { [weak self] in
            guard let sSelf = self else { return }
            sSelf.tableView.reloadData()
        }
    }
}