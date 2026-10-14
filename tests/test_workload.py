import random

import pytest

from clients.workload import filler, turn_words_for, validate_budget


def test_filler_is_deterministic_per_seed():
    assert filler(random.Random(1), 5) == filler(random.Random(1), 5)
    assert len(filler(random.Random(1), 7).split()) == 7


def test_turn_words_reaches_target_context():
    words = turn_words_for(context_tokens=28000, system_words=1500, turns=30, reply_tokens=48)
    total_tokens = (1500 + 30 * words) * 1.23 + 30 * 48
    assert 27000 <= total_tokens <= 28000


def test_turn_words_rejects_too_small_context():
    with pytest.raises(ValueError, match="system prompt"):
        turn_words_for(context_tokens=1000, system_words=1500, turns=10, reply_tokens=48)


def test_rejects_context_over_model_len():
    with pytest.raises(ValueError, match="max-model-len"):
        validate_budget(context_tokens=32768, max_tokens=48, max_model_len=32768)
    validate_budget(context_tokens=28000, max_tokens=48, max_model_len=32768)
