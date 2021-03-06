//
//  AppsManager.swift
//  ApiCore
//
//  Created by Ondrej Rafaj on 02/12/2018.
//

import Foundation
import Vapor
import ApiCore
import ErrorsCore
import Fluent
import FluentPostgreSQL
import SwiftShell
import MailCore


public class AppsManager {

    /// Overview app query
    static func overviewQuery(teams: Teams, on req: Request) throws -> QueryBuilder<ApiCoreDatabase, Cluster.Public> {
        let q = try Cluster.query(on: req).filter(\Cluster.teamId ~~ teams.ids).clusterFilters(on: req).clusterSorting(on: req).decode(Cluster.Public.self)
        return q
    }
    
    static func cluster(id clusterId: DbIdentifier, on req: Request) throws -> Future<Cluster> {
        return try req.me.teams().flatMap() { teams in
            return Cluster.query(on: req).filter(\Cluster.teamId ~~ teams.ids).filter(\Cluster.id == clusterId).first().map() { cluster in
                guard let cluster = cluster else {
                    throw ErrorsCore.HTTPError.notFound
                }
                return cluster
            }
        }
    }
    
    static func builds(clusterId: DbIdentifier? = nil, on req: Request) throws -> Future<Builds> {
        return try req.me.teams().flatMap() { teams in
            let q = try Build.query(on: req).filter(\Build.teamId ~~ teams.ids).sort(\Build.created, .descending).paginate(on: req).appFilters(on: req).decode(Build.Public.self)
            if let clusterId = clusterId {
                q.filter(\Build.clusterId == clusterId)
            }
            let cluster = try req.query.decode(Cluster.Id.self)
            if let id = cluster.value {
                q.filter(\Build.clusterId == id)
            }
            if let tags = req.query.app.tags, !tags.isEmpty {
                return Tag.query(on: req).filter(\Tag.teamId ~~ teams.ids).filter(\Tag.identifier ~~ tags.safeTagText()).all().flatMap() { tags in
                    guard !tags.isEmpty else {
                        return q.all()
                    }
                    // Account for the searched tags
                    var futures: [Future<UsedTag>] = []
                    for tag in tags {
                        try futures.append(UsedTagsManager.add(statsFor: tag, on: req))
                    }
                    return futures.flatten(on: req).flatMap() { _ in
                        let ids = tags.ids.map({ "'\($0.uuidString)'" })
                        let idString = ids.joined(separator: ", " )
                        // TODO: Use ?, ?, ? for the ids and bind them onto the query!!!
                        return req.withPooledConnection(to: .db) { conn in
                            let q = """
                            SELECT * FROM "Build"
                                WHERE "Build"."id" IN (
                                    SELECT "Build_Tag"."build_id"
                                        FROM "Build_Tag"
                                        WHERE "Build_Tag"."tag_id" IN (\(idString))
                                        GROUP BY "Build_Tag"."build_id" HAVING COUNT("Build_Tag"."build_id") = \(ids.count)
                                    )
                                ORDER BY "Build"."created" DESC
                                LIMIT 12 OFFSET 0
                            """
                            return conn.raw(q)
                                .all(decoding: Build.Public.self)
                        }
                    }
                }
            } else {
                return q.all()
            }
        }
    }
    
    /// Shared upload method
    static func upload(team: Team, apiKey uploadToken: ApiKey? = nil, on req: Request) throws -> Future<Response> {
        guard let teamId = team.id else {
            throw Team.Error.invalidTeam
        }
        // TODO: Change to copy file when https://github.com/vapor/core/pull/83 is done
        return req.fileData.flatMap() { (data) -> Future<Response> in
            // TODO: Think of a better way of identifying the iOS/Android apps
            let url = URL(fileURLWithPath: ApiCoreBase.configuration.storage.local.root)
                .appendingPathComponent(Build.localTempAppFolder(on: req).relativePath)
            return try EinstoreCoreBase.tempFileHandler.createFolderStructure(url: url, on: req).flatMap() { _ in
                let tempFilePath = URL(fileURLWithPath: ApiCoreBase.configuration.storage.local.root)
                    .appendingPathComponent(Build.localTempAppFile(on: req).relativePath)
                try data.write(to: tempFilePath)
                
                let output: RunOutput = SwiftShell.run("unzip", "-l", tempFilePath.path)
                
                let platform: Build.Platform
                if output.succeeded {
                    if output.stdout.contains("Payload/") {
                        platform = .ios
                    }
                    else if output.stdout.contains("AndroidManifest.xml") {
                        platform = .android
                    }
                    else {
                        throw ExtractorError.invalidAppContent
                    }
                }
                else {
                    throw ExtractorError.invalidAppContent
                }
                
                let extractor: Extractor = try BaseExtractor.decoder(file: tempFilePath.path, platform: platform, on: req)
                do {
                    return try extractor.process(teamId: teamId, on: req).flatMap() { build in
                        return try extractor.save(build, request: req).flatMap() { (_) -> Future<Response> in
                            let baseTags = uploadToken?.tags?.split(separator: ",").asStrings()
                            return try handleTags(on: req, baseTags: baseTags, team: team, build: build).flatMap() { (_) -> Future<Response> in
                                let inputLinkFromQuery = try? req.query.decode(Build.DetailTemplate.Link.self)
                                let user = (try? req.me.user()) ?? User(
                                    username: "",
                                    firstname: "",
                                    lastname: "",
                                    email: ""
                                )
                                let templateModel = try Build.DetailTemplate(
                                    link: inputLinkFromQuery?.value,
                                    build: build,
                                    on: req
                                )
                                
                                return try templateModel.setup(user: user.asDisplay(), on: req).flatMap() { _ in
                                    let templator = try req.make(Templator.self)
                                    let htmlFuture = try templator.get(name: "email.app-notification.html", data: templateModel, on: req)
                                    let plainFuture = try templator.get(name: "email.app-notification.plain", data: templateModel, on: req)
                                    return htmlFuture.flatMap() { htmlTemplate in
                                        return plainFuture.flatMap() { plainTemplate in
                                            let from = ApiCoreBase.configuration.mail.email
                                            let subject = "Install \(build.name) - \(ApiCoreBase.configuration.server.name)" // TODO: Localize!!!!!!
                                            return try team.users.query(on: req).all().flatMap() { teamUsers in
                                                let userEmails: [String] = teamUsers.map({ $0.email }) // QUESTION: Do we want name in the email too?
                                                let mail = Mailer.Message(from: from, to: from, bcc: userEmails, subject: subject, text: plainTemplate, html: htmlTemplate)
                                                return try req.mail.send(mail).flatMap() { mailResult in
                                                    switch mailResult {
                                                    case .success:
                                                        return try build.asResponse(.created, to: req)
                                                    default:
                                                        throw AuthError.emailFailedToSend
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    try extractor.cleanUp()
                    throw error
                }
            }
        }
    }
    
    /// Handle tags during upload
    static func handleTags(on req: Request, baseTags: [String]? = nil, team: Team, build: Build) throws -> Future<Tags> {
        var stringTags: [String] = baseTags ?? []
        
        // Process info tags
        if EinstoreCoreBase.configuration.tagsFromInfo.enable {
            if EinstoreCoreBase.configuration.tagsFromInfo.commit, let commit = build.info?.sourceControl?.commit?.id {
                stringTags.append("commit_\(commit)")
            }
            if EinstoreCoreBase.configuration.tagsFromInfo.pr, let pr = build.info?.sourceControl?.commit?.id {
                stringTags.append("pr_\(pr)")
            }
            if EinstoreCoreBase.configuration.tagsFromInfo.pm, let pm = build.info?.sourceControl?.commit?.id {
                stringTags.append("pm_\(pm)")
            }
        }
        
        // Process custom tags
        if req.http.url.query != nil {
            // Internal struct for tags in the URL
            struct Tags: Decodable {
                let value: String?
                let values: [String]?
                enum CodingKeys: String, CodingKey {
                    case value = "tags"
                    case values = "tag"
                }
            }
            // Decode tags
            if let tags = try? req.query.decode(Tags.self) {
                if let tags = tags.value?.split(separator: "|").map({ String($0) }) { // Parse tags as ?tags=tag1|tag2|tag3
                    stringTags.append(contentsOf: tags)
                } else if let tags = tags.values { // Parse tags as URL array (?tag[0]=tag1&tag[1]=tag2)
                    stringTags.append(contentsOf: tags)
                }
            }
        }
        guard !stringTags.isEmpty else {
            return req.eventLoop.newSucceededFuture(result: [])
        }
        return try TagsManager.save(tags: stringTags.safeTagText(), for: build, team: team, on: req)
    }
    
    static func delete(cluster: Cluster?, on req: Request) throws -> Future<Response> {
        guard let cluster = cluster, let teamId = cluster.teamId else {
            throw AppsController.Error.clusterInconsistency
        }
        return try req.me.verifiedTeam(id: teamId).flatMap() { team in
            return try cluster.builds.query(on: req).all().flatMap() { apps in
                var futures: [Future<Void>] = []
                try apps.forEach({
                    try futures.append(contentsOf: self.delete(build: $0, on: req))
                })
                
                return futures.flatten(on: req).flatMap() { _ in
                    return try cluster.delete(on: req).asResponse(to: req)
                }
            }
        }
    }
    
    static func delete(build: Build, countCluster cluster: Cluster? = nil, on req: Request) throws -> [Future<Void>] {
        var futures: [Future<Void>] = []
        // TODO: Refactor and split following into smaller methods!!
        
        // Handle cluster data
        if let cluster = cluster {
            if cluster.buildCount <= 1 {
                futures.append(cluster.delete(on: req).flatten())
            } else {
                cluster.buildCount -= 1
                let save = Build.query(on: req).sort(\Build.created, .descending).first().flatMap(to: Void.self) { build in
                    guard let build = build else {
                        throw AppsController.Error.clusterInconsistency
                    }
                    return cluster.add(build: build, on: req).flatten()
                }
                futures.append(save)
            }
        }
        
        let f = try build.tags.query(on: req).all().flatMap(to: Void.self) { tags in
            var futures: [Future<Void>] = []
            try tags.forEach({ tag in
                let tagFuture = try tag.builds.query(on: req).count().flatMap(to: Void.self) { count in
                    if count <= 1 {
                        return tag.delete(on: req).flatten()
                    }
                    else {
                        return build.tags.detach(tag, on: req).flatten()
                    }
                }
                futures.append(tagFuture)
            })
            
            // Delete app
            futures.append(build.delete(on: req).flatten())
            
            // Delete all files
            guard let path = build.targetFolderPath?.relativePath else {
                // TODO: Report if there was a problem somehow!!
                return req.future()
            }
            
            let fm = try req.makeFileCore()
            let deleteFuture = try fm.delete(file: path, on: req).catchMap({ err -> () in
                return Void()
            })
            futures.append(deleteFuture)
            return futures.flatten(on: req)
        }
        futures.append(f)
        
        return futures
    }
    
}
