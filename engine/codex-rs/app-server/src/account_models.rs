use crate::models::model_from_preset;
use crate::turnrail::SelectedAuthentication;
use crate::turnrail::TurnrailCoordinator;
use anyhow::Context;
use anyhow::Result;
use codex_app_server_protocol::Model;
use codex_core::config::Config;
use codex_model_provider::fetch_remote_models;
use codex_protocol::openai_models::ModelPreset;
use std::collections::HashSet;
use std::sync::Arc;

/// The official picker is global, so it advertises the intersection of assigned accounts.
pub(crate) async fn common_models(
    coordinator: &TurnrailCoordinator,
    config: &Config,
) -> Result<Vec<Model>> {
    let mut accounts = coordinator
        .assigned_authentications(config)
        .await?
        .into_iter();
    let first = accounts
        .next()
        .context("No accounts are assigned to folders")?;
    let mut common = account_models(&first, config).await?;
    for account in accounts {
        let available = account_models(&account, config).await?;
        common.retain_mut(|model| {
            let Some(other) = available.iter().find(|other| other.model == model.model) else {
                return false;
            };
            let no_effort_options = model.supported_reasoning_efforts.is_empty()
                && other.supported_reasoning_efforts.is_empty()
                && model.default_reasoning_effort == other.default_reasoning_effort;
            model.hidden |= other.hidden;
            model.supports_personality &= other.supports_personality;
            model.supported_reasoning_efforts.retain(|effort| {
                other
                    .supported_reasoning_efforts
                    .iter()
                    .any(|candidate| candidate.reasoning_effort == effort.reasoning_effort)
            });
            model
                .input_modalities
                .retain(|modality| other.input_modalities.contains(modality));
            model
                .additional_speed_tiers
                .retain(|tier| other.additional_speed_tiers.contains(tier));
            model.service_tiers.retain(|tier| {
                other
                    .service_tiers
                    .iter()
                    .any(|candidate| candidate.id == tier.id)
            });
            (no_effort_options || !model.supported_reasoning_efforts.is_empty())
                && !model.input_modalities.is_empty()
                && model.multi_agent_version == other.multi_agent_version
        });
    }
    let common_ids: HashSet<_> = common.iter().map(|model| model.model.clone()).collect();
    let default_index = common.iter().position(|model| !model.hidden);
    for (index, model) in common.iter_mut().enumerate() {
        model.is_default = Some(index) == default_index;
        if !model
            .supported_reasoning_efforts
            .iter()
            .any(|effort| effort.reasoning_effort == model.default_reasoning_effort)
            && let Some(first) = model.supported_reasoning_efforts.first()
        {
            model.default_reasoning_effort = first.reasoning_effort.clone();
        }
        if model
            .default_service_tier
            .as_ref()
            .is_some_and(|id| !model.service_tiers.iter().any(|tier| tier.id == *id))
        {
            model.default_service_tier = None;
        }
        if model
            .upgrade
            .as_ref()
            .is_some_and(|id| !common_ids.contains(id))
        {
            model.upgrade = None;
            model.upgrade_info = None;
        }
    }
    Ok(common)
}

/// Checks the selected account before any idle runtime is replaced or inference is submitted.
pub(crate) async fn validate_turn_model(
    account: &SelectedAuthentication,
    config: &Config,
    model: &str,
) -> Result<()> {
    let available = account_models(account, config).await?;
    anyhow::ensure!(
        available.iter().any(|candidate| candidate.model == model),
        "Model {model} is not available for the selected account {}. Choose an available model or change the folder's account priority.",
        account.account_id
    );
    Ok(())
}

async fn account_models(account: &SelectedAuthentication, config: &Config) -> Result<Vec<Model>> {
    let mut remote = fetch_remote_models(
        config.model_provider.clone(),
        Arc::clone(&account.auth_manager),
        config.http_client_factory(),
    )
    .await
    .with_context(|| format!("Could not fetch models for account {}", account.account_id))?;
    let mut slugs = HashSet::new();
    for model in &remote {
        anyhow::ensure!(
            !model.slug.is_empty() && slugs.insert(&model.slug),
            "Account {} returned an invalid model catalog",
            account.account_id
        );
    }
    remote.sort_by_key(|model| model.priority);
    let mut presets =
        ModelPreset::filter_by_auth(remote.into_iter().map(Into::into).collect(), true);
    ModelPreset::mark_default_by_picker_visibility(&mut presets);
    Ok(presets.into_iter().map(model_from_preset).collect())
}
