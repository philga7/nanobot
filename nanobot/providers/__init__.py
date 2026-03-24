"""LLM provider abstraction module."""

from nanobot.providers.base import LLMProvider, LLMResponse
from nanobot.providers.openai_codex_provider import OpenAICodexProvider
from nanobot.providers.azure_openai_provider import AzureOpenAIProvider

try:
    from nanobot.providers.litellm_provider import LiteLLMProvider
except ModuleNotFoundError:
    LiteLLMProvider = None  # type: ignore[assignment]

__all__ = ["LLMProvider", "LLMResponse", "OpenAICodexProvider", "AzureOpenAIProvider"]
if LiteLLMProvider is not None:
    __all__.append("LiteLLMProvider")
