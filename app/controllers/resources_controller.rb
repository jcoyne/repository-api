# frozen_string_literal: true

require 'base64'

# rubocop:disable Metrics/ClassLength
class ResourcesController < ApplicationController
  class BlobError < StandardError; end

  before_action :authorize_request
  before_action :validate_version

  # POST /resource
  # rubocop:disable Metrics/AbcSize
  # rubocop:disable Metrics/MethodLength
  def create
    begin
      request_dro = cocina_request_model
    rescue BlobError => e
      # Returning 500 because not clear whose fault it is.
      return render build_error('500', e, 'Error matching uploading files to file parameters.')
    end
    authorize! request_dro, with: ResourcePolicy

    result = BackgroundJobResult.create(output: {})
    IngestJob.perform_later(model_params: JSON.parse(request_dro.to_json), # Needs to be sidekiq friendly serialization
                            signed_ids: signed_ids(params),
                            background_job_result: result,
                            start_workflow: params.fetch(:accession, false),
                            assign_doi: params.fetch(:assign_doi, false),
                            priority: params.fetch(:priority, 'default'))

    render json: { jobId: result.id },
           location: result,
           status: :created
  end
  # rubocop:enable Metrics/AbcSize

  # PUT /resource/:id
  def update
    begin
      cocina_dro = cocina_update_model
    rescue BlobError => e
      # Returning 500 because not clear whose fault it is.
      return render build_error('500', e, 'Error matching uploading files to file parameters.')
    end

    authorize! cocina_dro, with: ResourcePolicy

    result = BackgroundJobResult.create(output: {})
    UpdateJob.perform_later(model_params: JSON.parse(cocina_dro.to_json), # Needs to be sidekiq friendly serialization
                            signed_ids: signed_ids(params),
                            version_description: params[:versionDescription],
                            background_job_result: result)

    render json: { jobId: result.id },
           location: result,
           status: :accepted
  end
  # rubocop:enable Metrics/MethodLength

  # This just proxies the response from DOR services app
  def show
    cocina_obj = Cocina::Models.without_metadata(Dor::Services::Client.object(params[:id]).find)
    authorize! cocina_obj, with: ResourcePolicy
    render json: cocina_obj
  rescue Dor::Services::Client::NotFoundResponse => e
    render build_error('404', e, "Object not found: #{params[:id]}")
  rescue Dor::Services::Client::UnexpectedResponse => e
    render build_error('500', e, 'Internal server error')
  end

  private

  CREATE_PARAMS_EXCLUDE_FROM_COCINA = %i[action controller resource accession priority assign_doi].freeze
  ID_NAMESPACE = 'https://cocina.sul.stanford.edu'

  def cocina_create_params
    params.except(*CREATE_PARAMS_EXCLUDE_FROM_COCINA).to_unsafe_h
  end

  def cocina_update_params
    params.except(:action, :controller, :resource, :id, :versionDescription).to_unsafe_h
  end

  def validate_version
    request_version = request.headers['X-Cocina-Models-Version']
    return if !request_version || request_version == Cocina::Models::VERSION

    error = StandardError.new("The API accepts cocina-models version #{Cocina::Models::VERSION} " \
                              "but you provided #{request_version}.  " \
                              'Run "bundle update" and then retry your request.')
    render build_error('400', error, 'Cocina-models version mismatch')
  end

  def cocina_update_model
    new_model_params = cocina_update_params.deep_dup
    decorate_file_sets(new_model_params)
    Cocina::Models.build(new_model_params)
  end

  def cocina_request_model
    new_model_params = cocina_create_params.deep_dup
    new_model_params[:version] = 1
    decorate_request_file_sets(new_model_params)
    Cocina::Models.build_request(new_model_params)
  end

  # Decorates the provided FileSets with the information we have in the ActiveStorage table.
  # externalIdentifier is also removed from the request.
  def decorate_file_sets(model_params)
    file_sets(model_params).each do |fileset|
      fileset[:version] = model_params[:version]
      fileset.dig(:structural, :contains).each do |file|
        # Only decorate ActiveStorage signed IDs
        next unless signed_id?(file[:externalIdentifier])

        decorate_file(file: file,
                      external_id: file_identifier(model_params[:externalIdentifier], fileset[:externalIdentifier]),
                      version: model_params[:version])
      end
    end
  end

  def file_identifier(object_id, resource_id)
    "#{ID_NAMESPACE}/file/#{object_id.delete_prefix('druid:')}-#{resource_id}/#{SecureRandom.uuid}"
  end

  # rubocop:disable Metrics/AbcSize
  def decorate_file(file:, version:, external_id: nil)
    blob = blob_for_signed_id(file.delete(:externalIdentifier), file[:filename])
    file[:externalIdentifier] = external_id if external_id
    file[:version] = version
    file[:size] = blob.byte_size
    file[:hasMimeType] = blob.content_type || 'application/octet-stream'
    declared_md5 = file[:hasMessageDigests].find { |digest| digest.fetch(:type) == 'md5' }.fetch(:digest)
    calculated_md5 = base64_to_hexdigest(blob.checksum)
    raise BlobError, "MD5 mismatch for #{file[:filename]}" if declared_md5 != calculated_md5
  end
  # rubocop:enable Metrics/AbcSize

  # Decorates the provided FileSets with the information we have in the ActiveStorage table.
  # externalIdentifier is also removed from the request.
  def decorate_request_file_sets(model_params)
    file_sets(model_params).each do |fileset|
      fileset[:version] = 1
      fileset.dig(:structural, :contains).each do |file|
        decorate_file(file: file, version: 1)
      end
    end
  end

  def blob_for_signed_id(signed_id, filename)
    file_id = ActiveStorage.verifier.verified(signed_id, purpose: :blob_id)
    ActiveStorage::Blob.find(file_id)
  rescue ActiveRecord::RecordNotFound
    raise BlobError, "Unable to find upload for #{filename} (#{signed_id})"
  end

  def file_sets(model_params)
    model_params.fetch(:structural, {}).fetch(:contains, [])
  end

  def signed_ids(model_params)
    {}.tap do |signed_ids|
      file_sets(model_params).flat_map do |fileset|
        fileset.dig(:structural, :contains).filter_map do |file|
          # Only include ActiveStorage signed IDs
          signed_ids[file[:filename]] = file[:externalIdentifier] if signed_id?(file[:externalIdentifier])
        end
      end
    end
  end

  # NOTE: sdr-api receives requests from both:
  #
  #   1. systems like H2 that rely on the API to deposit files to SDR; and
  #   2. users hand-creating objects via the sdr-client CLI.
  #
  # The latter use case allows a user to update an existing SDR object, e.g., to
  # amend an item's APO. This operation does not require sdr-api to handle files
  # and is merely passing through Cocina to SDR. One way we can tell whether a Cocina
  # structure depends on sdr-api to manage files is by sniffing files' external
  # identifiers. If the external identifier of a file is a legitimate HTTP(S) URI,
  # SDR already has a file on hand for the object, and sdr-api can simply pass through
  # the structure undecorated. If on the other hand the external identifier is not
  # an HTTP(S) URI, that is a signal that the originating user or system expects
  # the API to manage files for them.
  def signed_id?(file_id)
    !file_id.match?(%r{^https?://})
  end

  def base64_to_hexdigest(base64)
    Base64.decode64(base64).unpack1('H*')
  end

  # JSON-API error response. See https://jsonapi.org/.
  def build_error(error_code, err, msg)
    {
      json: {
        errors: [
          {
            status: error_code,
            title: msg,
            detail: err.message
          }
        ]
      },
      content_type: 'application/vnd.api+json',
      status: error_code
    }
  end
end
# rubocop:enable Metrics/ClassLength
