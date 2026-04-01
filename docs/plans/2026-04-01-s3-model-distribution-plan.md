# S3 Model Distribution Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add S3-based model distribution to lex-ollama so fleet nodes pull models from internal S3 instead of the public Ollama registry.

**Architecture:** New `Runners::S3Models` module uses `lex-s3` to download Ollama model manifests and blobs from S3. Two pull strategies: filesystem write (fast, works offline) and Ollama API (push_blob + create_model). Fleet broadcast is free via the LEX runner queue.

**Tech Stack:** Ruby, lex-s3 (aws-sdk-s3), Faraday, Ollama REST API

**Design doc:** `docs/plans/2026-04-01-s3-model-distribution-design.md`

---

### Task 1: Add lex-s3 dependency

**Files:**
- Modify: `lex-ollama.gemspec:29`
- Modify: `Gemfile` (if present, for local dev)

**Step 1: Add runtime dependency to gemspec**

In `lex-ollama.gemspec`, after the existing `faraday` dependency (line 29), add:

```ruby
spec.add_dependency 'lex-s3', '>= 0.2'
```

**Step 2: Run bundle install**

Run: `bundle install`
Expected: resolves lex-s3 and aws-sdk-s3 successfully

**Step 3: Commit**

```bash
git add lex-ollama.gemspec Gemfile.lock
git commit -m "add lex-s3 dependency for s3 model distribution"
```

---

### Task 2: Create S3Models runner with `list_s3_models`

**Files:**
- Create: `lib/legion/extensions/ollama/runners/s3_models.rb`
- Test: `spec/legion/extensions/ollama/runners/s3_models_spec.rb`

**Step 1: Write the failing test for `list_s3_models`**

```ruby
# spec/legion/extensions/ollama/runners/s3_models_spec.rb
# frozen_string_literal: true

require 'legion/extensions/s3/client'

RSpec.describe Legion::Extensions::Ollama::Runners::S3Models do
  let(:client_instance) { Legion::Extensions::Ollama::Client.new }
  let(:s3_client) { instance_double(Legion::Extensions::S3::Client) }

  before do
    allow(Legion::Extensions::S3::Client).to receive(:new).and_return(s3_client)
  end

  describe '#list_s3_models' do
    it 'lists models from S3 manifest keys' do
      allow(s3_client).to receive(:list_objects).with(
        bucket: 'legion',
        prefix: 'ollama/models/manifests/registry.ollama.ai/library/',
        max_keys: 1000
      ).and_return({
        objects: [
          { key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest', size: 512, last_modified: '2026-04-01' },
          { key: 'ollama/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest', size: 256, last_modified: '2026-04-01' }
        ],
        count: 2
      })

      result = client_instance.list_s3_models(bucket: 'legion', prefix: 'ollama/models')
      expect(result[:models]).to eq([
        { name: 'llama3', tag: 'latest' },
        { name: 'nomic-embed-text', tag: 'latest' }
      ])
      expect(result[:status]).to eq(200)
    end

    it 'returns empty list when no models exist' do
      allow(s3_client).to receive(:list_objects).and_return({ objects: [], count: 0 })

      result = client_instance.list_s3_models(bucket: 'legion', prefix: 'ollama/models')
      expect(result[:models]).to eq([])
    end
  end
end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/extensions/ollama/runners/s3_models_spec.rb -v`
Expected: FAIL — `NoMethodError: undefined method 'list_s3_models'`

**Step 3: Write the runner module**

```ruby
# lib/legion/extensions/ollama/runners/s3_models.rb
# frozen_string_literal: true

require 'legion/extensions/s3/client'
require 'legion/extensions/ollama/helpers/client'

module Legion
  module Extensions
    module Ollama
      module Runners
        module S3Models
          extend Legion::Extensions::Ollama::Helpers::Client

          OLLAMA_REGISTRY_PREFIX = 'manifests/registry.ollama.ai/library'

          def default_models_path
            ENV.fetch('OLLAMA_MODELS', File.join(Dir.home, '.ollama', 'models'))
          end

          def s3_model_client(**s3_opts)
            Legion::Extensions::S3::Client.new(**s3_opts)
          end

          def parse_model_ref(model)
            parts = model.split(':')
            { name: parts[0], tag: parts[1] || 'latest' }
          end

          def list_s3_models(bucket:, prefix: 'ollama/models', **s3_opts)
            s3 = s3_model_client(**s3_opts)
            manifest_prefix = "#{prefix}/#{OLLAMA_REGISTRY_PREFIX}/"
            resp = s3.list_objects(bucket: bucket, prefix: manifest_prefix, max_keys: 1000)

            models = resp[:objects].filter_map do |obj|
              relative = obj[:key].delete_prefix(manifest_prefix)
              parts = relative.split('/')
              next unless parts.length == 2

              { name: parts[0], tag: parts[1] }
            end

            { models: models, status: 200 }
          end

          include Legion::Extensions::Helpers::Lex if Legion::Extensions.const_defined?(:Helpers) &&
                                                      Legion::Extensions::Helpers.const_defined?(:Lex)
        end
      end
    end
  end
end
```

**Step 4: Wire into the module loader and Client class**

In `lib/legion/extensions/ollama.rb`, add after the blobs require (line 11):

```ruby
require 'legion/extensions/ollama/runners/s3_models'
```

In `lib/legion/extensions/ollama/client.rb`, add after `include Runners::Blobs` (line 21):

```ruby
include Runners::S3Models
```

**Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/legion/extensions/ollama/runners/s3_models_spec.rb -v`
Expected: 2 examples, 0 failures

**Step 6: Commit**

```bash
git add lib/legion/extensions/ollama/runners/s3_models.rb \
        lib/legion/extensions/ollama.rb \
        lib/legion/extensions/ollama/client.rb \
        spec/legion/extensions/ollama/runners/s3_models_spec.rb
git commit -m "add list_s3_models runner for s3 model distribution"
```

---

### Task 3: Add `import_from_s3` (filesystem write)

**Files:**
- Modify: `lib/legion/extensions/ollama/runners/s3_models.rb`
- Modify: `spec/legion/extensions/ollama/runners/s3_models_spec.rb`

**Step 1: Write the failing test**

Add to the s3_models_spec.rb, inside the main describe block:

```ruby
  describe '#import_from_s3' do
    let(:models_path) { Dir.mktmpdir('ollama_models') }
    let(:manifest_body) do
      {
        'schemaVersion' => 2,
        'mediaType' => 'application/vnd.docker.distribution.manifest.v2+json',
        'config' => { 'digest' => 'sha256:aaa111', 'size' => 100 },
        'layers' => [
          { 'digest' => 'sha256:bbb222', 'size' => 4_000_000_000 },
          { 'digest' => 'sha256:ccc333', 'size' => 512 }
        ]
      }
    end
    let(:manifest_json) { JSON.generate(manifest_body) }

    after { FileUtils.remove_entry(models_path) }

    it 'downloads manifest and blobs to local filesystem' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ body: manifest_json, content_type: 'application/json', content_length: manifest_json.length, key: '' })

      %w[sha256:aaa111 sha256:bbb222 sha256:ccc333].each do |digest|
        file_digest = digest.tr(':', '-')
        allow(s3_client).to receive(:get_object)
          .with(bucket: 'legion', key: "ollama/models/blobs/#{file_digest}")
          .and_return({ body: "blob_data_#{digest}", content_type: 'application/octet-stream', content_length: 10, key: '' })
      end

      result = client_instance.import_from_s3(model: 'llama3:latest', bucket: 'legion', models_path: models_path)

      expect(result[:result]).to be(true)
      expect(result[:blobs_downloaded]).to eq(3)
      expect(result[:status]).to eq(200)

      manifest_file = File.join(models_path, 'manifests', 'registry.ollama.ai', 'library', 'llama3', 'latest')
      expect(File.exist?(manifest_file)).to be(true)
      expect(File.read(manifest_file)).to eq(manifest_json)

      expect(File.exist?(File.join(models_path, 'blobs', 'sha256-bbb222'))).to be(true)
    end

    it 'skips blobs that already exist with matching size' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ body: manifest_json, content_type: 'application/json', content_length: manifest_json.length, key: '' })

      # Pre-create one blob with matching size
      blob_dir = File.join(models_path, 'blobs')
      FileUtils.mkdir_p(blob_dir)
      File.write(File.join(blob_dir, 'sha256-aaa111'), 'x' * 100)

      # Only the other two blobs should be downloaded
      %w[sha256:bbb222 sha256:ccc333].each do |digest|
        file_digest = digest.tr(':', '-')
        allow(s3_client).to receive(:get_object)
          .with(bucket: 'legion', key: "ollama/models/blobs/#{file_digest}")
          .and_return({ body: "blob_data_#{digest}", content_type: 'application/octet-stream', content_length: 10, key: '' })
      end

      result = client_instance.import_from_s3(model: 'llama3:latest', bucket: 'legion', models_path: models_path)

      expect(result[:blobs_downloaded]).to eq(2)
      expect(result[:blobs_skipped]).to eq(1)
    end

    it 'defaults tag to latest when not specified' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ body: manifest_json, content_type: 'application/json', content_length: manifest_json.length, key: '' })

      %w[sha256:aaa111 sha256:bbb222 sha256:ccc333].each do |digest|
        file_digest = digest.tr(':', '-')
        allow(s3_client).to receive(:get_object)
          .with(bucket: 'legion', key: "ollama/models/blobs/#{file_digest}")
          .and_return({ body: "blob_data_#{digest}", content_type: 'application/octet-stream', content_length: 10, key: '' })
      end

      result = client_instance.import_from_s3(model: 'llama3', bucket: 'legion', models_path: models_path)
      expect(result[:result]).to be(true)
    end
  end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/extensions/ollama/runners/s3_models_spec.rb -v`
Expected: FAIL — `NoMethodError: undefined method 'import_from_s3'`

**Step 3: Implement `import_from_s3`**

Add to `lib/legion/extensions/ollama/runners/s3_models.rb`, inside the `S3Models` module, before the `include` guard:

```ruby
          def import_from_s3(model:, bucket:, prefix: 'ollama/models', models_path: nil, **s3_opts)
            models_path ||= default_models_path
            ref = parse_model_ref(model)
            s3 = s3_model_client(**s3_opts)

            manifest_key = "#{prefix}/#{OLLAMA_REGISTRY_PREFIX}/#{ref[:name]}/#{ref[:tag]}"
            manifest_resp = s3.get_object(bucket: bucket, key: manifest_key)
            manifest = JSON.parse(manifest_resp[:body])

            all_digests = [manifest['config'], *manifest['layers']].compact
            downloaded = 0
            skipped = 0

            all_digests.each do |layer|
              digest = layer['digest']
              size = layer['size']
              file_digest = digest.tr(':', '-')
              local_path = File.join(models_path, 'blobs', file_digest)

              if File.exist?(local_path) && File.size(local_path) == size
                skipped += 1
                next
              end

              FileUtils.mkdir_p(File.dirname(local_path))
              blob_resp = s3.get_object(bucket: bucket, key: "#{prefix}/blobs/#{file_digest}")
              File.binwrite(local_path, blob_resp[:body])
              downloaded += 1
            end

            manifest_dir = File.join(models_path, 'manifests', 'registry.ollama.ai', 'library', ref[:name])
            FileUtils.mkdir_p(manifest_dir)
            File.write(File.join(manifest_dir, ref[:tag]), manifest_resp[:body])

            { result: true, model: model, blobs_downloaded: downloaded, blobs_skipped: skipped, status: 200 }
          end
```

Also add `require 'json'` and `require 'fileutils'` at the top of the file.

**Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/legion/extensions/ollama/runners/s3_models_spec.rb -v`
Expected: 5 examples, 0 failures

**Step 5: Commit**

```bash
git add lib/legion/extensions/ollama/runners/s3_models.rb \
        spec/legion/extensions/ollama/runners/s3_models_spec.rb
git commit -m "add import_from_s3 for filesystem-based model distribution"
```

---

### Task 4: Add `sync_from_s3` (Ollama API)

**Files:**
- Modify: `lib/legion/extensions/ollama/runners/s3_models.rb`
- Modify: `spec/legion/extensions/ollama/runners/s3_models_spec.rb`

**Step 1: Write the failing test**

Add to the s3_models_spec.rb, inside the main describe block:

```ruby
  describe '#sync_from_s3' do
    let(:faraday_conn) { instance_double(Faraday::Connection) }
    let(:manifest_body) do
      {
        'schemaVersion' => 2,
        'mediaType' => 'application/vnd.docker.distribution.manifest.v2+json',
        'config' => { 'digest' => 'sha256:aaa111', 'size' => 100 },
        'layers' => [
          { 'digest' => 'sha256:bbb222', 'size' => 4_000_000_000, 'mediaType' => 'application/vnd.ollama.image.model' },
          { 'digest' => 'sha256:ccc333', 'size' => 512, 'mediaType' => 'application/vnd.ollama.image.template' }
        ]
      }
    end
    let(:manifest_json) { JSON.generate(manifest_body) }

    before do
      allow(client_instance).to receive(:client).and_return(faraday_conn)
    end

    it 'pushes blobs through Ollama API and creates model' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ body: manifest_json, content_type: 'application/json', content_length: manifest_json.length, key: '' })

      # check_blob returns false for all (none cached)
      %w[sha256:aaa111 sha256:bbb222 sha256:ccc333].each do |digest|
        allow(faraday_conn).to receive(:head).with("/api/blobs/#{digest}")
          .and_return(instance_double(Faraday::Response, status: 404))

        file_digest = digest.tr(':', '-')
        allow(s3_client).to receive(:get_object)
          .with(bucket: 'legion', key: "ollama/models/blobs/#{file_digest}")
          .and_return({ body: "blob_data_#{digest}", content_type: 'application/octet-stream', content_length: 10, key: '' })

        allow(faraday_conn).to receive(:post).with("/api/blobs/#{digest}")
          .and_yield(instance_double(Faraday::Request, headers: {}).tap do |req|
            allow(req).to receive(:body=)
            allow(req).to receive(:headers).and_return({})
          end).and_return(instance_double(Faraday::Response, status: 201))
      end

      allow(faraday_conn).to receive(:post).with('/api/create', hash_including(model: 'llama3:latest'))
        .and_return(instance_double(Faraday::Response, body: { 'status' => 'success' }, status: 200))

      result = client_instance.sync_from_s3(model: 'llama3:latest', bucket: 'legion')
      expect(result[:result]).to be(true)
      expect(result[:status]).to eq(200)
    end

    it 'skips blobs already present in Ollama' do
      allow(s3_client).to receive(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/manifests/registry.ollama.ai/library/llama3/latest')
        .and_return({ body: manifest_json, content_type: 'application/json', content_length: manifest_json.length, key: '' })

      # aaa111 already exists, others do not
      allow(faraday_conn).to receive(:head).with('/api/blobs/sha256:aaa111')
        .and_return(instance_double(Faraday::Response, status: 200))

      %w[sha256:bbb222 sha256:ccc333].each do |digest|
        allow(faraday_conn).to receive(:head).with("/api/blobs/#{digest}")
          .and_return(instance_double(Faraday::Response, status: 404))

        file_digest = digest.tr(':', '-')
        allow(s3_client).to receive(:get_object)
          .with(bucket: 'legion', key: "ollama/models/blobs/#{file_digest}")
          .and_return({ body: "blob_data_#{digest}", content_type: 'application/octet-stream', content_length: 10, key: '' })

        allow(faraday_conn).to receive(:post).with("/api/blobs/#{digest}")
          .and_yield(instance_double(Faraday::Request, headers: {}).tap do |req|
            allow(req).to receive(:body=)
            allow(req).to receive(:headers).and_return({})
          end).and_return(instance_double(Faraday::Response, status: 201))
      end

      allow(faraday_conn).to receive(:post).with('/api/create', hash_including(model: 'llama3:latest'))
        .and_return(instance_double(Faraday::Response, body: { 'status' => 'success' }, status: 200))

      result = client_instance.sync_from_s3(model: 'llama3:latest', bucket: 'legion')
      expect(result[:result]).to be(true)

      expect(s3_client).not_to have_received(:get_object)
        .with(bucket: 'legion', key: 'ollama/models/blobs/sha256-aaa111')
    end
  end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/extensions/ollama/runners/s3_models_spec.rb -v`
Expected: FAIL — `NoMethodError: undefined method 'sync_from_s3'`

**Step 3: Implement `sync_from_s3`**

Add to `lib/legion/extensions/ollama/runners/s3_models.rb`, inside the `S3Models` module:

```ruby
          def sync_from_s3(model:, bucket:, prefix: 'ollama/models', **opts)
            ref = parse_model_ref(model)
            s3_opts = opts.reject { |k, _| k == :host }
            s3 = s3_model_client(**s3_opts)

            manifest_key = "#{prefix}/#{OLLAMA_REGISTRY_PREFIX}/#{ref[:name]}/#{ref[:tag]}"
            manifest_resp = s3.get_object(bucket: bucket, key: manifest_key)
            manifest = JSON.parse(manifest_resp[:body])

            all_digests = [manifest['config'], *manifest['layers']].compact

            all_digests.each do |layer|
              digest = layer['digest']
              existing = check_blob(digest: digest, **opts)
              next if existing[:result]

              file_digest = digest.tr(':', '-')
              blob_resp = s3.get_object(bucket: bucket, key: "#{prefix}/blobs/#{file_digest}")
              push_blob(digest: digest, body: blob_resp[:body], **opts)
            end

            model_name = "#{ref[:name]}:#{ref[:tag]}"
            create_model(model: model_name, from: model_name, **opts)

            { result: true, model: model_name, status: 200 }
          end
```

**Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/legion/extensions/ollama/runners/s3_models_spec.rb -v`
Expected: 7 examples, 0 failures

**Step 5: Commit**

```bash
git add lib/legion/extensions/ollama/runners/s3_models.rb \
        spec/legion/extensions/ollama/runners/s3_models_spec.rb
git commit -m "add sync_from_s3 for api-based model distribution"
```

---

### Task 5: Add `import_default_models` convenience method

**Files:**
- Modify: `lib/legion/extensions/ollama/runners/s3_models.rb`
- Modify: `spec/legion/extensions/ollama/runners/s3_models_spec.rb`

**Step 1: Write the failing test**

Add to the s3_models_spec.rb:

```ruby
  describe '#import_default_models' do
    let(:models_path) { Dir.mktmpdir('ollama_models') }
    let(:manifest_body) do
      {
        'schemaVersion' => 2,
        'config' => { 'digest' => 'sha256:aaa111', 'size' => 100 },
        'layers' => []
      }
    end
    let(:manifest_json) { JSON.generate(manifest_body) }

    after { FileUtils.remove_entry(models_path) }

    it 'imports each model from the default_models list' do
      allow(s3_client).to receive(:get_object).and_return({
        body: manifest_json, content_type: 'application/json', content_length: manifest_json.length, key: ''
      })
      allow(s3_client).to receive(:get_object)
        .with(hash_including(key: /blobs/))
        .and_return({ body: 'data', content_type: 'application/octet-stream', content_length: 4, key: '' })

      result = client_instance.import_default_models(
        default_models: ['llama3:latest', 'nomic-embed-text:latest'],
        bucket: 'legion',
        models_path: models_path
      )

      expect(result[:result].length).to eq(2)
      expect(result[:result]).to all(include(result: true))
      expect(result[:status]).to eq(200)
    end
  end
```

**Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/legion/extensions/ollama/runners/s3_models_spec.rb -v`
Expected: FAIL — `NoMethodError: undefined method 'import_default_models'`

**Step 3: Implement `import_default_models`**

Add to the `S3Models` module:

```ruby
          def import_default_models(default_models:, bucket:, **opts)
            results = default_models.map do |model|
              import_from_s3(model: model, bucket: bucket, **opts)
            end

            { result: results, status: 200 }
          end
```

**Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/legion/extensions/ollama/runners/s3_models_spec.rb -v`
Expected: 8 examples, 0 failures

**Step 5: Commit**

```bash
git add lib/legion/extensions/ollama/runners/s3_models.rb \
        spec/legion/extensions/ollama/runners/s3_models_spec.rb
git commit -m "add import_default_models convenience method"
```

---

### Task 6: Update Client spec for new runner methods

**Files:**
- Modify: `spec/legion/extensions/ollama/client_spec.rb`

**Step 1: Add respond_to expectations**

Add to the `'runner inclusion'` describe block in `client_spec.rb`:

```ruby
    it { is_expected.to respond_to(:list_s3_models) }
    it { is_expected.to respond_to(:import_from_s3) }
    it { is_expected.to respond_to(:sync_from_s3) }
    it { is_expected.to respond_to(:import_default_models) }
```

**Step 2: Run full test suite**

Run: `bundle exec rspec -v`
Expected: all examples pass, 0 failures

**Step 3: Commit**

```bash
git add spec/legion/extensions/ollama/client_spec.rb
git commit -m "add s3_models runner inclusion tests to client spec"
```

---

### Task 7: Run pre-push pipeline

**Step 1: Run full test suite**

Run: `bundle exec rspec`
Expected: 0 failures

**Step 2: Run rubocop auto-fix**

Run: `bundle exec rubocop -A`
Stage all modified files.

**Step 3: Run rubocop lint check**

Run: `bundle exec rubocop`
Expected: 0 offenses

**Step 4: Bump version**

In `lib/legion/extensions/ollama/version.rb`, bump `VERSION` from `'0.2.0'` to `'0.3.0'` (minor bump — new feature).

**Step 5: Update CHANGELOG.md**

Add entry:

```markdown
## [0.3.0] - 2026-04-01

### Added
- S3 model distribution via new `Runners::S3Models` module
- `list_s3_models` to discover models in S3 mirror
- `import_from_s3` for direct filesystem model import (works without Ollama running)
- `sync_from_s3` for Ollama API-based model import (push_blob + create_model)
- `import_default_models` convenience method for fleet provisioning
- Runtime dependency on `lex-s3` for S3 operations
```

**Step 6: Update README.md**

Add S3 model distribution section documenting the four new methods and settings.

**Step 7: Commit and push**

```bash
git add -A
git commit -m "bump version to 0.3.0, update changelog and readme for s3 model distribution"
git push # pipeline-complete
```
