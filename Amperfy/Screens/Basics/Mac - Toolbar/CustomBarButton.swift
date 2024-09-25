//
//  CustomBarButton.swift
//  Amperfy
//
//  Created by David Klopp on 22.08.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import UIKit

#if targetEnvironment(macCatalyst)

// MacOS BarButtonItems can not be disabled. Thats, why we create a custom BarButtonItem.
class CustomBarButton: UIBarButtonItem, Refreshable {
    static let defaultPointSize: CGFloat = 18.0
    static let smallPointSize: CGFloat = 14.0
    static let defaultSize = CGSize(width: 32, height: 22)

    let pointSize: CGFloat

    var inUIButton: UIButton? {
        self.customView as? UIButton
    }

    var hovered: Bool = false {
        didSet {
            self.updateButtonBackgroundColor()
        }
    }

    var active: Bool = false {
        didSet{
            guard let image = self.inUIButton?.configuration?.image else { return }
            self.updateImage(image: image)
            self.updateButtonBackgroundColor()
        }
    }

    var currentTintColor: UIColor {
        if (self.active) {
            .label
        } else {
            .secondaryLabel
        }
    }

    var currentBackgroundColor: UIColor {
        if (self.hovered || self.active) {
            .hoveredBackgroundColor
        } else {
            .clear
        }
    }

    func updateButtonBackgroundColor() {
        self.inUIButton?.backgroundColor = self.currentBackgroundColor
    }

    func updateImage(image: UIImage) {
        self.inUIButton?.configuration?.image = image.styleForNavigationBar(pointSize: self.pointSize, tintColor: self.currentTintColor)
    }

    func createInUIButton(config: UIButton.Configuration, size: CGSize) -> UIButton? {
        let button = UIButton(configuration: config)
        button.imageView?.contentMode = .scaleAspectFit

        // influence the highlighted area
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        button.heightAnchor.constraint(equalToConstant: size.height).isActive = true

        return button
    }

    override var isEnabled: Bool {
        get { super.isEnabled }
        set(newValue) {
            super.isEnabled = newValue
            self.customView?.isUserInteractionEnabled = newValue
        }
    }

    init(image: UIImage?, pointSize: CGFloat = ControlBarButton.defaultPointSize) {
        self.pointSize = pointSize
        super.init()

        var config = UIButton.Configuration.gray()
        config.macIdiomStyle = .borderless
        config.image = image?.styleForNavigationBar(pointSize: self.pointSize, tintColor: self.currentTintColor)
        let button = createInUIButton(config: config, size: Self.defaultSize)
        button?.addTarget(self, action: #selector(self.clicked(_:)), for: .touchUpInside)
        button?.layer.cornerRadius = 5
        self.customView = button

        // Recreate the system button background highlight
        self.installHoverGestureRecognizer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func installHoverGestureRecognizer() {
        let recognizer = UIHoverGestureRecognizer(target: self, action: #selector(self.hoverButton(_:)))
        self.inUIButton?.addGestureRecognizer(recognizer)
    }

    @objc private func hoverButton(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began:
            self.hovered = true
        case .ended, .cancelled, .failed:
            self.hovered = false
        default:
            break
        }
    }

    @objc func clicked(_ sender: UIButton) {

    }

    func reload() {
        self.updateButtonBackgroundColor()
        guard let image = self.inUIButton?.configuration?.image else { return }
        self.updateImage(image: image)
    }
}

#endif