# Contributing to CTO Factory Agent

Thank you for your interest in contributing!

## How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Test locally with `./scripts/deploy.sh`
5. Commit (`git commit -m 'feat: my feature'`)
6. Push to your fork (`git push origin feature/my-feature`)
7. Open a Pull Request

## Development Setup

```bash
git clone https://github.com/no-name-labs/cto-lobster.git
cd cto-lobster
./scripts/deploy.sh
```

## Code Style

- Shell scripts: follow existing patterns in `scripts/`
- Lobster files: YAML-safe (no multiline strings in `-m` args)
- Python: standard library only, no external dependencies
- Prompt files: concise, actionable, absolute paths

## Reporting Issues

Open an issue at https://github.com/no-name-labs/cto-lobster/issues

Include:
- OS (Ubuntu/macOS)
- OpenClaw version (`openclaw --version`)
- Lobster version (`lobster version`)
- Error output or session logs

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
