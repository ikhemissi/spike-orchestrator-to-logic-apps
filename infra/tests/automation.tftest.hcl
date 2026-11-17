mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000001"
      subscription_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}

mock_provider "random" {}

override_resource {
  target          = azurerm_automation_account.main
  override_during = plan

  values = {
    id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Automation/automationAccounts/aa-test"
    hybrid_service_url = "https://automation.test.example"
  }
}

override_resource {
  target          = azurerm_user_assigned_identity.logicapp
  override_during = plan

  values = {
    id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-test-logicapp"
    client_id    = "00000000-0000-0000-0000-000000000002"
    principal_id = "00000000-0000-0000-0000-000000000003"
    tenant_id    = "00000000-0000-0000-0000-000000000001"
  }
}

override_resource {
  target          = azurerm_windows_virtual_machine.worker
  override_during = plan

  values = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Compute/virtualMachines/vm-hw01"
  }
}

override_resource {
  target          = random_uuid.worker
  override_during = plan

  values = {
    result = "00000000-0000-0000-0000-000000000004"
  }
}

variables {
  environment_name = "test"
  subscription_id  = "00000000-0000-0000-0000-000000000000"
  location         = "francecentral"
  tags             = ""
  deployer_ip      = "203.0.113.8"
}

run "automation_uses_hybrid_worker_credential" {
  command = plan

  assert {
    condition     = azurerm_automation_account.main.sku_name == "Basic" && azurerm_automation_account.main.identity[0].type == "SystemAssigned"
    error_message = "The Automation account must use the Basic SKU and a system-assigned identity."
  }

  assert {
    condition     = azurerm_automation_runtime_environment.powershell.runtime_language == "PowerShell" && azurerm_automation_runtime_environment.powershell.runtime_version == "7.4"
    error_message = "The runbook runtime must use the PowerShell 7.4 environment."
  }

  assert {
    condition     = azurerm_automation_runbook.convert_and_move.runtime_environment_name == azurerm_automation_runtime_environment.powershell.name && azurerm_automation_runbook.convert_and_move.content != ""
    error_message = "The published conversion runbook must use the configured runtime environment."
  }

  assert {
    condition     = azurerm_automation_hybrid_runbook_worker_group.files.name == "hwg-spike-files" && azurerm_automation_hybrid_runbook_worker_group.files.credential_name == "cred-svc-azauto"
    error_message = "The hybrid worker group must use the custom run-as credential by default."
  }

  assert {
    condition     = azurerm_automation_credential.svc_azauto.name == "cred-svc-azauto" && azurerm_automation_credential.svc_azauto.username == "svc-azauto"
    error_message = "The Automation credential asset must use the worker-local svc-azauto account."
  }

  assert {
    condition = alltrue([
      for worker_name in local.worker_names :
      azurerm_automation_hybrid_runbook_worker.worker[worker_name].worker_id == random_uuid.worker[worker_name].result &&
      azurerm_automation_hybrid_runbook_worker.worker[worker_name].vm_resource_id == azurerm_windows_virtual_machine.worker[worker_name].id &&
      azurerm_virtual_machine_extension.hybrid_worker[worker_name].publisher == "Microsoft.Azure.Automation.HybridWorker" &&
      azurerm_virtual_machine_extension.hybrid_worker[worker_name].type == "HybridWorkerForWindows" &&
      azurerm_virtual_machine_extension.hybrid_worker[worker_name].type_handler_version == "1.1" &&
      azurerm_virtual_machine_extension.hybrid_worker[worker_name].auto_upgrade_minor_version &&
      jsondecode(azurerm_virtual_machine_extension.hybrid_worker[worker_name].settings).AutomationAccountURL == azurerm_automation_account.main.hybrid_service_url
    ])
    error_message = "Every VM worker must be registered and have the Hybrid Worker extension configured."
  }

  assert {
    condition     = alltrue([for category in azurerm_monitor_diagnostic_setting.automation.enabled_log : contains(["JobLogs", "JobStreams"], category.category)]) && length(azurerm_monitor_diagnostic_setting.automation.enabled_log) == 2
    error_message = "Automation diagnostics must include JobLogs and JobStreams."
  }

  assert {
    condition     = azurerm_role_assignment.logicapp_automation_job_operator.role_definition_name == "Automation Job Operator" && azurerm_role_assignment.logicapp_automation_job_operator.principal_id == azurerm_user_assigned_identity.logicapp.principal_id && azurerm_role_assignment.logicapp_automation_job_operator.scope == azurerm_automation_account.main.id && azurerm_role_assignment.logicapp_automation_runbook_operator.role_definition_name == "Automation Runbook Operator" && azurerm_role_assignment.logicapp_automation_runbook_operator.principal_id == azurerm_user_assigned_identity.logicapp.principal_id && azurerm_role_assignment.logicapp_automation_runbook_operator.scope == azurerm_automation_account.main.id
    error_message = "The Logic App identity must receive both Automation operator roles."
  }
}

run "automation_can_run_as_local_system" {
  command = plan

  variables {
    worker_run_as_custom_credential = false
  }

  assert {
    condition     = azurerm_automation_hybrid_runbook_worker_group.files.credential_name == null
    error_message = "Disabling the custom credential must leave the group without a run-as credential."
  }
}
