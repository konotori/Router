//
//  Middleware.swift
//
//
//  Created by Amitayus on 12/11/25.
//

import SwiftUI
import Combine

@MainActor
open class BaseRouter<NavRoute: Hashable, SheetRoute: Identifiable, CoverRoute: Identifiable>: ObservableObject {
	// MARK: - States
	
	@Published public var path = NavigationPath()
	@Published private var globalSheet: SheetRoute?
	@Published private var globalFullScreenCover: CoverRoute?
	private var routeStack: [NavRoute] = []
	private var pathChangeCancellable: AnyCancellable?
	private var middlewares: [any Middleware<NavRoute, SheetRoute, CoverRoute>] = []
	
	public var sheetBinding: Binding<SheetRoute?> {
		Binding(
			get: { self.globalSheet },
			set: { [weak self] newValue in
				guard let self else {
					return
				}
				
				if newValue == nil, self.globalSheet != nil {
					// Dismiss gesture or manual nil
					dismissSheet()
				}
			}
		)
	}
	
	public var fullScreenCoverBinding: Binding<CoverRoute?> {
		Binding(
			get: { self.globalFullScreenCover },
			set: { [weak self] newValue in
				guard let self else {
					return
				}
				
				if newValue == nil, self.globalFullScreenCover != nil {
					// Dismiss gesture or manual nil
					self.dismissFullScreenCover()
				}
			}
		)
	}
	
	// MARK: - Init
	
	public init() {
		setupPathObserver()
	}
	
	// MARK: - Public Properties
	
	public var currentRoute: NavRoute? {
		routeStack.last
	}
	
	public var currentRouteName: String {
		currentRoute.map { String(describing: $0) } ?? "Root"
	}
	
	public var routeHistory: [NavRoute] {
		routeStack
	}
	
	public var navigationDepth: Int {
		routeStack.count
	}
	
	public var canPop: Bool {
		!routeStack.isEmpty && !path.isEmpty
	}
	
	/// Get routes from current position to root
	public var routesToRoot: [NavRoute] {
		Array(routeStack.reversed())
	}
	
	/// Get routes from root to current position
	public var routesFromRoot: [NavRoute] {
		routeStack
	}
	
	// MARK: - Public Navigation Methods
	
	public func push(_ route: NavRoute, strategy: PushStrategy = .always) {
		processNavigationMiddleware(event: .push(route, strategy: strategy)) {
			switch strategy {
			case .always:
				path.append(route)
				routeStack.append(route)
				
			case .ifNotExists:
				if !containsRoute(route) {
					path.append(route)
					routeStack.append(route)
				}
				
			case .navigateOrPush:
				if let existingIndex = routeStack.firstIndex(of: route) {
					navigateToExisting(at: existingIndex)
				} else {
					path.append(route)
					routeStack.append(route)
				}
			}
		}
	}
	
	public func pop() {
		guard canPop else {
			#if DEBUG
			print("⚠️ Navigation: pop() ignored - empty stack")
			#endif
			return
		}
		
		processNavigationMiddleware(event: .pop) {
			path.removeLast()
			routeStack.removeLast()
		}
	}
	
	public func popTo(_ route: NavRoute) {
		guard let index = routeStack.firstIndex(of: route) else {
			#if DEBUG
			print("⚠️ Navigation: popTo() ignored - route not found: \(route)")
			#endif
			return
		}
		
		processNavigationMiddleware(event: .popTo(route)) {
			navigateToExisting(at: index)
		}
	}
	
	public func popToRoot() {
		guard canPop else {
			return
		}
		
		processNavigationMiddleware(event: .popToRoot) {
			path.removeLast(path.count)
			routeStack.removeAll()
		}
	}
	
	public func replace(with route: NavRoute) {
		processNavigationMiddleware(event: .replace(route)) {
			if canPop {
				path.removeLast()
				routeStack.removeLast()
			}
			path.append(route)
			routeStack.append(route)
		}
	}
	
	public func presentSheet(_ route: SheetRoute) {
		processSheetPresentationMiddleware(event: .presentSheet(route)) {
			globalSheet = route
		}
	}
	
	public func dismissSheet() {
		processSheetPresentationMiddleware(event: .dismissSheet) {
			globalSheet = nil
		}
	}
	
	public func presentFullScreenCover(_ route: CoverRoute) {
		processCoverPresentationMiddleware(event: .presentFullScreenCover(route)) {
			globalFullScreenCover = route
		}
	}
	
	public func dismissFullScreenCover() {
		processCoverPresentationMiddleware(event: .dismissFullScreenCover) {
			globalFullScreenCover = nil
		}
	}
	
	// MARK: - Public Query Methods
	
	public func isCurrentRoute(_ route: NavRoute) -> Bool {
		currentRoute == route
	}
	
	public func containsRoute(_ route: NavRoute) -> Bool {
		routeStack.contains(route)
	}
	
	// MARK: - Public Middleware Management Methods
	
	public func addMiddleware<M: Middleware>(_ middleware: M) where M.NavRoute == NavRoute, M.SheetRoute == SheetRoute,
																	M.CoverRoute == CoverRoute {
																		middlewares.append(middleware)
																	}
	
	public func clearMiddlewares() {
		middlewares.removeAll()
	}
	
	// MARK: - Private Navigation Methods
	
	private func navigateToExisting(at index: Int) {
		guard index < routeStack.count - 1 else {
			return
		}
		
		let routesToPop = routeStack.count - index - 1
		path.removeLast(routesToPop)
		routeStack.removeLast(routesToPop)
	}
	
	// MARK: - Private Navigation Middleware Helpers
	
	private func processNavigationMiddleware(event: NavigationEvent<NavRoute>, handler: () -> Void) {
		guard shouldProcessNavigation(event) else {
			return
		}
		
		handler()
		didProcessNavigation(event)
	}
	
	private func shouldProcessNavigation(_ event: NavigationEvent<NavRoute>) -> Bool {
		for middleware in middlewares {
			guard middleware.shouldProcess(event, for: self) else {
				#if DEBUG
				print("🚫 Navigation: blocked by \(type(of: middleware))")
				#endif
				return false
			}
		}
		return true
	}
	
	private func didProcessNavigation(_ event: NavigationEvent<NavRoute>) {
		for middleware in middlewares {
			middleware.didProcess(event, for: self)
		}
	}
	
	// MARK: - Private Sheet Presentation Middleware Helpers
	
	private func processSheetPresentationMiddleware(event: PresentationEvent<SheetRoute>, handler: () -> Void) {
		guard shouldProcessSheetPresentation(event) else {
			return
		}
		
		handler()
		didProcessSheetPresentation(event)
	}
	
	private func shouldProcessSheetPresentation(_ event: PresentationEvent<SheetRoute>) -> Bool {
		for middleware in middlewares {
			guard middleware.shouldProcess(event, for: self) else {
				#if DEBUG
				print("🚫 Sheet Presentation: blocked by \(type(of: middleware))")
				#endif
				return false
			}
		}
		return true
	}
	
	private func didProcessSheetPresentation(_ event: PresentationEvent<SheetRoute>) {
		for middleware in middlewares {
			middleware.didProcess(event, for: self)
		}
	}
	
	// MARK: - Private Sheet Presentation Middleware Helpers
	
	private func processCoverPresentationMiddleware(event: PresentationEvent<CoverRoute>, handler: () -> Void) {
		guard shouldProcessCoverPresentation(event) else {
			return
		}
		
		handler()
		didProcessCoverPresentation(event)
	}
	
	private func shouldProcessCoverPresentation(_ event: PresentationEvent<CoverRoute>) -> Bool {
		for middleware in middlewares {
			guard middleware.shouldProcess(event, for: self) else {
				#if DEBUG
				print("🚫 Cover Presentation: blocked by \(type(of: middleware))")
				#endif
				return false
			}
		}
		return true
	}
	
	private func didProcessCoverPresentation(_ event: PresentationEvent<CoverRoute>) {
		for middleware in middlewares {
			middleware.didProcess(event, for: self)
		}
	}
	
	// MARK: - Path Synchronization
	
	private func setupPathObserver() {
		pathChangeCancellable = $path
			.dropFirst()
			.sink { [weak self] newPath in
				self?.syncRouteStack(with: newPath)
			}
	}
	
	private func syncRouteStack(with path: NavigationPath) {
		let pathCount = path.count
		let stackCount = routeStack.count
		
		if pathCount < stackCount {
			let difference = stackCount - pathCount
			routeStack.removeLast(difference)
		}
	}
}
