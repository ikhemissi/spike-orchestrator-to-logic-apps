# 01 — Built-in connectors as published by the Logic Apps runtime

Read on 2026-11-17 from the deployed app's management API (`…/hostruntime/runtime/webhooks/workflow/api/management/operationGroups/{connector}` and `…/operations/{operation}?$expand=properties/manifest`, `api-version=2018-11-01`). `*` = required; `authProvider.` = nested under `authProvider` in `connections.json`.

## Connection parameters

```text
Ftp: disableCertificateValidation:bool, disableConnectionCache:bool, enableBinaryMode:bool, enableSsl:bool, password:securestring*, portNumber:int, serverAddress:string*, username:string*
Sftp: disableConnectionCache:bool, password:securestring, portNumber:int, rootDirectory:string, sshHostAddress:string*, sshHostKeyFingerprint:string, sshPrivateKey:string, sshPrivateKeyPassphrase:securestring, username:string*
FileSystem: mountPath:string, password:securestring*, rootFolder:string*, username:string*
AzureBlob [connectionString]: connectionString:securestring*
AzureBlob [ActiveDirectoryOAuth]: authProvider.Authority:string, authProvider.ClientId:string*, authProvider.CredentialType:string, authProvider.Password:securestring*, authProvider.Pfx:securestring*, authProvider.Secret:securestring*, authProvider.Tenant:string*, authProvider.Type:string*, blobStorageEndpoint:string*
AzureBlob [ManagedServiceIdentity]: authProvider.Identity:string*, authProvider.Type:string*, blobStorageEndpoint:string*, managedIdentityType:string*
azureAutomation [ActiveDirectoryOAuth]: authProvider.Authority:string, BaseUri:string, authProvider.ClientId:string*, authProvider.CredentialType:string, authProvider.Password:securestring*, authProvider.Pfx:securestring*, authProvider.Secret:securestring*, authProvider.Tenant:string*, authProvider.Type:string*
azureAutomation [ManagedServiceIdentity]: BaseUri:string, authProvider.Identity:string, authProvider.Type:string*
```

## Operations used by the workflows (inputs)

```text
Ftp/listFilesInFolder(folderPath:string*)
Ftp/getFtpFileContent(filePath:string*)
Ftp/createFile(fileContent:None*, filePath:string*, getAllFileMetadata:boolean)
Ftp/deleteFtpFile(filePath:string*, skipIfFileNotPresent:boolean)
Sftp/getMetadata(fileOrFolderPath:string*)
Sftp/uploadFileContent(content:string, filePath:string*, overWriteFileIfExists:boolean*)
Sftp/renameFile(fetchMetadata:boolean, filePath:string*, newFileName:string*)
FileSystem/getFileMetadata(filePath:string*)
FileSystem/createFile(body:None, filePath:string*)
FileSystem/listFolder(enableRecursiveListing:boolean, folderPath:string*)
FileSystem/renameFile(filePath:string*, newName:string*)
AzureBlob/uploadBlob(blobName:string*, containerName:string*, content:None*, overrideIfExists:string)
AzureBlob/blobExists(blobName:string*, containerName:string*)
azureAutomation/createJob(automationAccount:None*, hybridAutomationWorkerGroup:None, resourceGroup:None*, runbookName:None*, runbookParameters:object, subscriptionId:None*, waitForJob:boolean)
azureAutomation/getJobStatus(automationAccount:None*, jobId:None*, resourceGroup:None*, subscriptionId:None*)
azureAutomation/getJobOutput(automationAccount:None*, jobId:None*, resourceGroup:None*, subscriptionId:None*)
```

## All operations

```text
== Ftp
  T whenFtpFilesAreAddedOrModified
  A getFtpFileContent
  A getFtpFileContentV2
  A getFileMetadata
  A createFile
  A updateFile
  A deleteFtpFile
  A listFilesInFolder
  A extractArchive
== Sftp
  T whenFilesAreAddedOrModified
  T whenFileIsAddedOrModified
  A getFileContent
  A uploadFileContent
  A getMetadata
  A listFolder
  A deleteFile
  A createFolder
  A renameFile
  A copyFile
  A getFileContentV2
  A extractArchive
  A deleteFolder
== FileSystem
  T whenFilesAreAdded
  T whenFilesAreAddedOrModified
  A appendFile
  A copyFile
  A createFile
  A deleteFile
  A getFileContent
  A getFileContentV2
  A getFileMetadata
  A listFolder
  A renameFile
  A updateFile
  A extractArchive
== AzureBlob
  T whenABlobIsAddedOrModified
  A blobExists
  A deleteBlob
  A deleteBlobFromUri
  A readBlob
  A readBlobFromUri
  A uploadBlob
  A uploadBlobFromUri
  A listBlobs
  A listBlobsFromUri
  A listBlobDirectories
  A listContainers
  A getBlobSASUri
  A getBlobSASUriFromUri
  A getBlobMetadata
  A getBlobMetadataFromUri
  A getContainerMetadata
  A copyBlob
  A copyBlobFromUri
  A getAccessPolicies
  A setBlobTier
  A setBlobTierFromUri
  A extractArchiveFromBlobPath
  A extractArchiveFromUri
  A extractArchiveFromContent
== azureAutomation
  A createJob
  A getJobStatus
  A getJobOutput
```
