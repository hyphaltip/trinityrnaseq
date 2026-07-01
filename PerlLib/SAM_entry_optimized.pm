package SAM_entry;

use strict;
use warnings;
use Carp;

use constant {
    FLAG_PAIRED          => 0x0001,
    FLAG_PROPER_PAIR     => 0x0002,
    FLAG_QUERY_UNMAPPED  => 0x0004,
    FLAG_MATE_UNMAPPED   => 0x0008,
    FLAG_QUERY_STRAND    => 0x0010,
    FLAG_MATE_STRAND     => 0x0020,
    FLAG_FIRST_IN_PAIR   => 0x0040,
    FLAG_SECOND_IN_PAIR  => 0x0080,
    FLAG_NOT_PRIMARY     => 0x0100,
    FLAG_FAIL_VENDOR_QC  => 0x0200,
    FLAG_DUPLICATE       => 0x0400,
};

my $CIGAR_REGEX = qr/(\d+)([A-Z])/;

sub new {
    my $packagename = shift;
    my ($line) = @_;

    unless (defined $line) {
        confess "Error, need sam text line as parameter";
    }

    chomp $line;

    my @fields = split(/\t/, $line);
    
    my $self = bless {
        _line => $line,
        _fields => \@fields,
        _cigar_parsed => undef,
        _cigar_genome_span => undef,
        _cigar_read_span => undef,
        _flag_cached => undef,
    }, $packagename;
    
    return $self;
}

sub _parse_flag {
    my $self = shift;
    unless (defined $self->{_flag_cached}) {
        $self->{_flag_cached} = $self->{_fields}[1];
    }
    return $self->{_flag_cached};
}

sub _get_bit_val {
    my $self = shift;
    my ($bit_position) = @_;
    return $self->_parse_flag() & $bit_position;
}

sub _set_bit_val {
    my $self = shift;
    my ($bit_position, $bit_val) = @_;
    unless (defined $bit_position && defined $bit_val) {
        confess "Error, need bit position and value";
    }
    
    my $flag = $self->_parse_flag();
    if ($bit_val) {
        $flag |= $bit_position;
    }
    else {
        $flag &= ~$bit_position;
    }
    
    $self->{_fields}[1] = $flag;
    $self->{_flag_cached} = $flag;
    return;
}

sub get_original_line { return $_[0]->{_line} // '' }
sub get_fields { return @{$_[0]->{_fields}} }
sub get_read_name { return $_[0]->{_fields}[0] // '' }
sub get_core_read_name { 
    my $self = shift;
    my $read_name = $self->get_read_name();
    $read_name =~ s|/\d$||;
    return $read_name;
}

sub reconstruct_full_read_name {
    my $self = shift;
    my $read_name = $self->get_core_read_name();
    if ($self->is_first_in_pair()) { $read_name .= "/1"; }
    elsif ($self->is_second_in_pair()) { $read_name .= "/2"; }
    return $read_name;
}

sub get_scaffold_name { return $_[0]->{_fields}[2] // '' }
sub get_aligned_position { return $_[0]->{_fields}[3] // 0 }
sub get_scaffold_position { return shift->get_aligned_position() }

sub get_scaffold_start_position {
    my $self = shift;
    my ($lend, $rend) = $self->get_genome_span();
    return $self->get_query_strand() eq '+' ? $lend : $rend;
}

sub get_read_group {
    my $self = shift;
    if ($self->{_line} =~ /RG:Z:(\S+)/) {
        return $1;
    }
    return undef;
}

sub get_cigar_alignment { return $_[0]->{_fields}[5] // '*' }
sub get_mapping_quality { return $_[0]->{_fields}[4] // 0 }
sub get_sequence { return $_[0]->{_fields}[9] // '' }
sub get_quality_scores { return $_[0]->{_fields}[10] // '' }
sub get_inferred_insert_size { return $_[0]->{_fields}[8] // 0 }
sub get_mate_scaffold_name { return $_[0]->{_fields}[6] // '*' }
sub get_mate_scaffold_position { return $_[0]->{_fields}[7] // 0 }

sub set_mate_scaffold_name {
    $_[0]->{_fields}[6] = $_[1];
    return;
}

sub set_mate_scaffold_position {
    $_[0]->{_fields}[7] = $_[1];
    return;
}

sub get_flag { return $_[0]->{_fields}[1] // 0 }
sub set_flag {
    my ($self, $flag) = @_;
    confess "Error, need flag value" unless defined $flag;
    $self->{_fields}[1] = $flag;
    $self->{_flag_cached} = $flag;
    return;
}

sub is_paired { shift->_get_bit_val(FLAG_PAIRED) }
sub set_paired { shift->_set_bit_val(FLAG_PAIRED, @_) }

sub is_proper_pair { shift->_get_bit_val(FLAG_PROPER_PAIR) }
sub set_proper_pair { shift->_set_bit_val(FLAG_PROPER_PAIR, @_) }

sub is_query_unmapped { shift->_get_bit_val(FLAG_QUERY_UNMAPPED) }
sub set_query_unmapped { shift->_set_bit_val(FLAG_QUERY_UNMAPPED, @_) }

sub is_mate_unmapped { shift->_get_bit_val(FLAG_MATE_UNMAPPED) }
sub set_mate_unmapped { shift->_set_bit_val(FLAG_MATE_UNMAPPED, @_) }

sub is_duplicate { shift->_get_bit_val(FLAG_DUPLICATE) }
sub set_duplicate { shift->_set_bit_val(FLAG_DUPLICATE, @_) }

sub get_query_strand { 
    shift->_get_bit_val(FLAG_QUERY_STRAND) ? '-' : '+';
}

sub set_query_strand {
    my ($self, $strand) = @_;
    confess "Error, strand value must be [+-]" unless $strand eq '+' || $strand eq '-';
    $self->_set_bit_val(FLAG_QUERY_STRAND, $strand eq '-' ? 1 : 0);
}

sub get_mate_strand { 
    shift->_get_bit_val(FLAG_MATE_STRAND) ? '-' : '+';
}

sub set_mate_strand {
    my ($self, $strand) = @_;
    confess "Error, strand value must be [+-]" unless $strand eq '+' || $strand eq '-';
    $self->_set_bit_val(FLAG_MATE_STRAND, $strand eq '-' ? 1 : 0);
}

sub is_first_in_pair { shift->_get_bit_val(FLAG_FIRST_IN_PAIR) }
sub set_first_in_pair { shift->_set_bit_val(FLAG_FIRST_IN_PAIR, @_) }

sub is_second_in_pair { shift->_get_bit_val(FLAG_SECOND_IN_PAIR) }
sub set_second_in_pair { shift->_set_bit_val(FLAG_SECOND_IN_PAIR, @_) }

sub get_query_transcribed_strand {
    my ($self, $SS_lib_type) = @_;
    
    confess "Error, SS_lib_type required" unless $SS_lib_type;
    
    my $aligned_strand = $self->get_query_strand();
    my $opposite_strand = $aligned_strand eq '+' ? '-' : '+';
    my $transcribed_strand;
    
    if (!$self->is_paired()) {
        confess "Error, cannot have $SS_lib_type library type with unpaired reads" 
            unless $SS_lib_type =~ /^(F|R)$/;
        $transcribed_strand = $SS_lib_type eq "F" ? $aligned_strand : $opposite_strand;
    } else {
        confess "Error, cannot have $SS_lib_type library type with paired reads"
            unless $SS_lib_type =~ /^(FR|RF)$/;
        
        if ($self->is_first_in_pair()) {
            $transcribed_strand = $SS_lib_type eq "FR" ? $aligned_strand : $opposite_strand;
        } else {
            $transcribed_strand = $SS_lib_type eq "FR" ? $opposite_strand : $aligned_strand;
        }
    }
    
    return $transcribed_strand;
}

sub toString {
    my $self = shift;
    my @fields = @{$self->{_fields}};
    if ($self->is_paired()) {
        $fields[0] = $self->get_core_read_name();
    }
    return join("\t", @fields);
}

sub _parse_cigar {
    my $self = shift;
    
    if (defined $self->{_cigar_parsed}) {
        return $self->{_cigar_parsed};
    }
    
    my $alignment = $self->get_cigar_alignment();
    return [] if $alignment eq '*' || !$alignment;
    
    my @ops;
    while ($alignment =~ /$CIGAR_REGEX/g) {
        my ($len, $code) = ($1, $2);
        push @ops, { len => $len, code => $code };
    }
    
    $self->{_cigar_parsed} = \@ops;
    return \@ops;
}

sub get_alignment_coords {
    my $self = shift;
    
    my $genome_lend = $self->get_aligned_position();
    my $alignment = $self->get_cigar_alignment();
    
    return ([], []) if $alignment eq '*' || !$alignment;
    
    my @ops = @{$self->_parse_cigar()};
    
    my $query_lend = 0;
    $genome_lend--;
    
    my ($sum_hardmasked_query, @genome_coords, @query_coords);
    
    for my $op (@ops) {
        my $len = $op->{len};
        my $code = $op->{code};
        
        if ($code eq 'M') {
            my $genome_rend = $genome_lend + $len;
            my $query_rend = $query_lend + $len;
            push @genome_coords, [$genome_lend + 1, $genome_rend];
            push @query_coords, [$query_lend + 1, $query_rend];
            $genome_lend = $genome_rend;
            $query_lend = $query_rend;
        }
        elsif ($code eq 'D' || $code eq 'N') {
            $genome_lend += $len;
        }
        elsif ($code eq 'I' || $code eq 'S') {
            $query_lend += $len;
        }
        elsif ($code eq 'H') {
            $query_lend += $len;
            $sum_hardmasked_query += $len;
        }
    }
    
    if ($self->get_query_strand() eq '-') {
        my $read_len = length($self->get_sequence()) + ($sum_hardmasked_query // 0);
        my @revcomp_coords;
        for my $coordset (@query_coords) {
            my ($lend, $rend) = @$coordset;
            push @revcomp_coords, [$read_len - $lend + 1, $read_len - $rend + 1];
        }
        @query_coords = @revcomp_coords;
    }
    
    return (\@genome_coords, \@query_coords);
}

sub get_genome_span {
    my $self = shift;
    
    if (defined $self->{_cigar_genome_span}) {
        return @{$self->{_cigar_genome_span}};
    }
    
    my ($genome_coords, $query_coords) = $self->get_alignment_coords();
    
    return (0, 0) unless @$genome_coords;
    
    my @all_coords = map { @$_ } @$genome_coords;
    @all_coords = sort { $a <=> $b } @all_coords;
    
    $self->{_cigar_genome_span} = [shift(@all_coords), pop(@all_coords)];
    return @{$self->{_cigar_genome_span}};
}

sub get_read_span {
    my $self = shift;
    
    if (defined $self->{_cigar_read_span}) {
        return @{$self->{_cigar_read_span}};
    }
    
    my ($genome_coords, $query_coords) = $self->get_alignment_coords();
    
    return (0, 0) unless @$query_coords;
    
    my @all_coords = map { @$_ } @$query_coords;
    @all_coords = sort { $a <=> $b } @all_coords;
    
    $self->{_cigar_read_span} = [shift(@all_coords), pop(@all_coords)];
    return @{$self->{_cigar_read_span}};
}

sub get_alignment_length {
    my $self = shift;
    
    my @ops = @{$self->_parse_cigar()};
    my $sum_len = 0;
    
    for my $op (@ops) {
        $sum_len += $op->{len} if $op->{code} eq 'M';
    }
    
    return $sum_len;
}

1;