//
//  NotificationClient.swift
//  AzurePush
//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License.
//

#if os(iOS)

import UIKit
import Foundation
import AzureCore

internal class NotificationClient {
    private static let apiVersion = "2013-04"

    internal static let shared: NotificationClient = NotificationClient()

    internal lazy var session = URLSession(configuration: .default)

    private var isConfigured = false

    private var path: String = ""

    private var endpoint: URL!

    private var tokenProvider: TokenProvider!

    private var localStorage: LocalStorage!

    private let decoder = RegistrationDecoder()

    // MARK: - Configuration

    internal func configure(withHubName hubName: String, andConnectionString string: String) throws {
        let params = try ConnectionParams(connectionString: string)

        self.endpoint = params.endpoint
        self.path = hubName
        self.tokenProvider = TokenProvider(connectionParams: params)
        self.localStorage = LocalStorage(notificationHubPath: hubName)
        self.isConfigured = true
    }

    // MARK: - Registration

    internal func registerForRemoteNotifications(withDeviceToken deviceToken: Data, tags: [String] = [], completion: @escaping (Response<Registration>) -> Void) {
        guard isConfigured else {
            completion(Response(AzurePush.Error.notConfigured))
            return
        }

        let token = deviceToken.hexString
        let payload = Registration.payload(forDeviceToken: token, andTags: tags)

        registerForRemoteNotifications(withDeviceToken: token, name: Registration.defaultName, andPayload: payload, completion: completion)
    }

    internal func registerForRemoteNotifications(withDeviceToken deviceToken: Data, usingTemplate template: Registration.Template, priority: String? = nil, tags: [String] = [], completion: @escaping (Response<Registration>) -> Void) {
        guard isConfigured else {
            completion(Response(AzurePush.Error.notConfigured))
            return
        }

        if let error = Registration.Template.validate(name: template.name) {
            completion(Response(error))
            return
        }

        let token = deviceToken.hexString
        let payload = Registration.payload(forDeviceToken: token, template: template, priority: priority, andTags: tags)

        registerForRemoteNotifications(withDeviceToken: token, name: template.name, andPayload: payload, completion: completion)
    }

    // MARK: - Unregistration

    internal func cancel(registration: Registration, completion: @escaping (Response<Data>) -> Void) {
        guard isConfigured else {
            completion(Response(AzurePush.Error.notConfigured))
            return
        }

        delete(registration: registration, completion: completion)
    }

    internal func cancelAllRegistrations(forDeviceToken deviceToken: Data, completion: @escaping (Response<Data>) -> Void) {
        guard isConfigured else {
            completion(Response(AzurePush.Error.notConfigured))
            return
        }

        let dispatchGroup = DispatchGroup()

        let token = deviceToken.hexString

        getRegistrations(forDeviceToken: token) { [weak self] response in
            guard response.result.isSuccess else {
                completion(Response(request: response.request, data: response.data, response: response.response, result: .failure(response.result.error!)))
                return
            }

            for registration in response.result.resource! {
                dispatchGroup.enter()

                self?.delete(registration: registration) { r in
                    if r.result.isFailure {
                        completion(r)
                        return
                    }

                    dispatchGroup.leave()
                }
            }

            dispatchGroup.notify(queue: .main, execute: {
                completion(Response("".data(using: .utf8)!))
            })
        }
    }

    // MARK: - Private helpers

    private func registerForRemoteNotifications(withDeviceToken token: String, name: String, andPayload payload: String, completion: @escaping (Response<Registration>) -> Void) {
        guard localStorage.needsRefresh else {
            createOrUpdate(registrationWithName: name, payload: payload, completion: completion)
            return
        }

        let refreshedDeviceToken = self.refreshedDeviceToken(withNewDeviceToken: token)
        getRegistrations(forDeviceToken: refreshedDeviceToken) { [weak self] response in
            switch response.result {
            case .failure(let error):
                completion(Response(error))
            case .success(_):
                self?.localStorage.refresh(withDeviceToken: refreshedDeviceToken)
                self?.createOrUpdate(registrationWithName: name, payload: payload, completion: completion)
            }
        }
    }
    
    private func createOrUpdate(registrationWithName name: String, payload: String, completion: @escaping (Response<Registration>) -> Void) {
        guard let registration = localStorage[name] else {
            createAndUpsert(registrationWithName: name, payload: payload, completion: completion)
            return
        }

        upsert(registrationWithId: registration.id, name: name, payload: payload) { [weak self] response in
            if response.response?.statusCode == HttpStatusCode.gone.rawValue {
                self?.createAndUpsert(registrationWithName: name, payload: payload, completion: completion)
                return
            }

            completion(response)
        }
    }

    private func createAndUpsert(registrationWithName name: String, payload: String, completion: @escaping (Response<Registration>) -> Void) {
        let url = URL(string: "\(endpoint.absoluteString)\(path)/registrationids/?api-version=\(NotificationClient.apiVersion)")!

        sendRequest(url: url, method: .post, payload: payload) { [weak self] response in
            guard let location = response.value(forHeader: .location), let locationUrl = URL(string: location) else {
                completion(Response(request: response.request, data: response.data, response: response.response, result: .failure(AzurePush.Error.unknown)))
                return
            }

            self?.upsert(registrationWithId: locationUrl.registrationId, name: name, payload: payload, completion: completion)
        }
    }

    private func upsert(registrationWithId id: String, name: String, payload: String, completion: @escaping (Response<Registration>) -> Void) {
        let url = URL(string: "\(endpoint.absoluteString)\(path)/Registrations/\(id)?api-version=\(NotificationClient.apiVersion)")!

        sendRequest(url: url, method: .put, payload: payload) { [weak self] response in
            completion(response.map { data in
                let registrations = self?.decoder.decode(from: data) ?? []
                self?.localStorage[name] = registrations.first
                return registrations.first!
            })
        }
    }

    private func refreshedDeviceToken(withNewDeviceToken newDeviceToken: String) -> String {
        guard let token = localStorage.deviceToken else {
            return newDeviceToken
        }

        return token
    }
    
    private func getRegistrations(forDeviceToken deviceToken: String, completion: @escaping (Response<[Registration]>) -> Void) {
        let url = URL(string: "\(endpoint.absoluteString)\(path)/Registrations/?$filter=deviceToken+eq+'\(deviceToken)'&api-version=\(NotificationClient.apiVersion)")!

        sendRequest(url: url, method: .get) { [weak self] response in
            completion(response.map { data in
                let registrations = self?.decoder.decode(from: data) ?? []
                registrations.forEach { self?.localStorage[$0.name] = $0 }
                return registrations
            })
        }
    }

    private func delete(registration: Registration, completion: @escaping (Response<Data>) -> Void) {
        let url = URL(string: "\(endpoint.absoluteString)\(path)/Registrations/\(registration.id)?api-version=\(NotificationClient.apiVersion)")!

        sendRequest(url: url, method: .delete, etag: "*") { [weak self] response in
            if response.result.isSuccess {
                self?.localStorage.removeRegistration(withName: registration.name)
            }

            completion(response)
        }
    }

    private func sendRequest(url: URL, method: HttpMethod, payload: String? = nil, etag: String? = nil, completion: @escaping (Response<Data>) -> Void) {
        guard let authToken = tokenProvider.getToken(for: url) else {
            completion(Response(AzurePush.Error.failedToRetrieveAuthorizationToken))
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60.0)
        request.httpMethod = method.rawValue
        request.httpBody = payload?.data(using: .utf8)
        request.addValue(authToken, forHTTPHeaderField: HttpHeader.authorization.rawValue)
        request.setValue(NotificationClient.userAgent, forHTTPHeaderField: HttpHeader.userAgent.rawValue)
        etag.flatMap { request.addValue("\"\($0)\"", forHTTPHeaderField: HttpHeader.ifMatch.rawValue) }
        payload.flatMap { request.setValue($0.contentType, forHTTPHeaderField: HttpHeader.contentType.rawValue) }

        session.dataTask(with: request) { data, response, error in
            let httpResponse = response as? HTTPURLResponse

            if let error = error {
                completion(Response(request: request, data: data, response: httpResponse, result: .failure(error)))
                return
            }

            if let data = data, let httpResponse = httpResponse, let statusCode = HttpStatusCode(rawValue: httpResponse.statusCode), statusCode.isSuccess {
                completion(Response(request: request, data: data, response: httpResponse, result: .success(data)))
            } else {
                completion(Response(request: request, data: data, response: httpResponse, result: .failure(AzurePush.Error.unknown)))
            }
        }.resume()
    }
}

// MARK: - Extensions

extension NotificationClient {
    internal static var userAgent: String {
        return "NOTIFICATIONHUBS/\(NotificationClient.apiVersion)(api-origin=IosSdk; os=\(UIDevice.current.systemName); os_version=\(UIDevice.current.systemVersion);)"
    }
}

extension Data {
    internal var hexString: String {
        return map { String(format: "%02.2hhx", $0) }.joined()
    }
}

extension String {
    internal var contentType: String {
        if self.starts(with: "{") {
            return "application/json"
        }

        return "application/xml"
    }
}

extension HttpStatusCode {
    internal var isSuccess: Bool {
        return rawValue >= 200 && rawValue < 300
    }
}

extension Response {
    internal func value(forHeader header: HttpHeader) -> String? {
        return self.response?.allHeaderFields[header.rawValue] as? String
    }
}

extension URL {
    fileprivate var registrationId: String {
        return self.lastPathComponent
    }
}

#endif
