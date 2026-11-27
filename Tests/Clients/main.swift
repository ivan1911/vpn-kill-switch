// Prints VPNClient.allCases as "id|display name|bundle identifier" lines, the
// same shape as client_table in Guard/config.sh. Tests/clients.sh compares them.
for client in VPNClient.allCases {
    print("\(client.rawValue)|\(client.name)|\(client.bundleIdentifier)")
}
