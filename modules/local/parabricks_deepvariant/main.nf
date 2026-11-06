/*
 * PARABRICKS_DEEPVARIANT
 * -----------------------------------------------------------------------------
 * GPU replacement for nf-core DEEPVARIANT_RUNDEEPVARIANT using NVIDIA Parabricks
 * `pbrun deepvariant`. Same inputs and same emit names as
 * DEEPVARIANT_RUNDEEPVARIANT, so CALL_SNV can swap one for the other.
 *
 * Selected automatically in CALL_SNV when `gpu` is in the -profile list.
 */

process PARABRICKS_DEEPVARIANT {
    tag "$meta.id"
    label 'process_high'
    label 'process_gpu'

    container 'nvcr.io/nvidia/clara/clara-parabricks:4.7.1-1'

    input:
    tuple val(meta),  path(input), path(index), path(intervals)
    tuple val(meta2), path(fasta)
    tuple val(meta3), path(fai)
    tuple val(meta4), path(gzi)       // unused: Parabricks needs an uncompressed fasta
    tuple val(meta5), path(par_bed)   // unused: pass haploid/PAR flags via ext.args if needed

    output:
    tuple val(meta), path("${prefix}.vcf.gz")             , emit: vcf
    tuple val(meta), path("${prefix}.vcf.gz.{tbi,csi}")   , emit: vcf_index
    tuple val(meta), path("${prefix}.g.vcf.gz")           , emit: gvcf
    tuple val(meta), path("${prefix}.g.vcf.gz.{tbi,csi}") , emit: gvcf_index
    path "versions.yml"                                   , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    if (workflow.profile.tokenize(',').intersect(['conda', 'mamba']).size() >= 1) {
        error "PARABRICKS_DEEPVARIANT does not support Conda. Please use Docker / Singularity / Podman instead."
    }
    def args         = task.ext.args ?: ''
    prefix           = task.ext.prefix ?: "${meta.id}"
    def interval_cmd = intervals ? "--interval-file ${intervals}" : ''
    def num_gpus     = task.accelerator ? "--num-gpus ${task.accelerator.request}" : ''
    """
    pbrun deepvariant \\
        --ref ${fasta} \\
        --in-bam ${input} \\
        --out-variants ${prefix}.g.vcf.gz \\
        --gvcf \\
        ${interval_cmd} \\
        ${num_gpus} \\
        ${args}

    # With --gvcf, Parabricks writes a plain VCF next to the gVCF.
    # Normalise its name to ${prefix}.vcf.gz.
    if   [ -f ${prefix}.vcf.gz ]; then :
    elif [ -f ${prefix}.vcf ];    then bgzip -@ ${task.cpus} ${prefix}.vcf
    else echo "Parabricks did not produce ${prefix}.vcf(.gz)" >&2; ls -la >&2; exit 1
    fi

    # Guard against the known silent 0-byte-output failure mode
    test -s ${prefix}.vcf.gz   || { echo "Parabricks produced an empty VCF"  >&2; exit 1; }
    test -s ${prefix}.g.vcf.gz || { echo "Parabricks produced an empty gVCF" >&2; exit 1; }

    # Index if Parabricks did not already; fall back to pbrun indexgvcf if tabix is absent
    for f in ${prefix}.vcf.gz ${prefix}.g.vcf.gz; do
        if [ -f "\$f.tbi" ] || [ -f "\$f.csi" ]; then continue; fi
        if command -v tabix >/dev/null 2>&1; then
            tabix -p vcf "\$f"
        else
            pbrun indexgvcf --input "\$f"
        fi
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        parabricks: \$(pbrun version | grep -m1 '^pbrun:' | sed 's/^pbrun:[[:space:]]*//')
    END_VERSIONS
    """

    stub:
    prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo "" | gzip > ${prefix}.vcf.gz
    touch ${prefix}.vcf.gz.tbi
    echo "" | gzip > ${prefix}.g.vcf.gz
    touch ${prefix}.g.vcf.gz.tbi

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        parabricks: 4.7.1-1
    END_VERSIONS
    """
}
