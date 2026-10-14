"""Synthetic agent-session text: a long system prompt plus growing tool results."""
import random

# Measured locally: 1500 filler words -> ~1846 Qwen3 prompt tokens.
TOKENS_PER_WORD = 1.23

WORDS = ("node pod cache token batch queue shard replica latency tensor kernel "
         "socket buffer thread commit branch deploy rollback metric trace span "
         "volume secret ingress gateway probe quota cluster region bucket").split()


def filler(rng: random.Random, n_words: int) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(n_words))


def turn_words_for(context_tokens: int, system_words: int, turns: int, reply_tokens: int) -> int:
    """Words per tool result so the final turn's context is about `context_tokens`."""
    if turns <= 0:
        raise ValueError("turns must be positive")
    budget_words = (context_tokens - turns * reply_tokens) / TOKENS_PER_WORD - system_words
    if budget_words < turns:
        raise ValueError(f"context_tokens={context_tokens} leaves no room after the system prompt "
                         f"({system_words} words) and {turns} replies")
    return int(budget_words / turns)


def validate_budget(context_tokens: int, max_tokens: int, max_model_len: int) -> None:
    if context_tokens + max_tokens > max_model_len:
        raise ValueError(f"context_tokens ({context_tokens}) + max_tokens ({max_tokens}) exceeds "
                         f"--max-model-len ({max_model_len})")
