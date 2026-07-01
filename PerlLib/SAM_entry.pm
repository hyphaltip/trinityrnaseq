package SAM_entry;

use strict;
use warnings;
use Carp;

my $CIGAR_REGEX = qr/(\d+)([A-Z])/;

# --- Constructor ---

sub new {
    my ($class, $line) = @_;
    confess "Error, need sam text line as parameter" unless defined $line;

    chomp $line;
    my @fields = split(/\t/, $line);

    my $self = bless {
        _line => $line,
        _fields => \@fields,
    }, $class;

    return $self;
}

# --- Basic accessors ---

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
    if ($self->{_line} =~ /RG:Z:(\S+)/) { return $1; }
    return undef;
}

sub get_cigar_alignment { return $_[0]->{_fields}[5] // '*' }
sub get_mapping_quality { return $_[0]->{_fields}[4] // 0 }
sub get_sequence { return $_[0]->{_fields}[9] // '' }
sub get_quality_scores { return $_[0]->{_fields}[10] // '' }
sub get_inferred_insert_size { return $_[0]->{_fields}[8] // 0 }

sub get_mate_scaffold_name { return $_[0]->{_fields}[6] // '*' }
sub get_mate_scaffold_position { return $_[0]->{_fields}[7] // 0 }

sub set_mate_scaffold_name { $_[0]->{_fields}[6] = $_[1]; return; }
sub set_mate_scaffold_position { $_[0]->{_fields}[7] = $_[1]; return; }

sub toString {
    my $self = shift;
    my @fields = @{$self->{_fields}};
    if ($self->is_paired()) {
        $fields[0] = $self->get_core_read_name();
    }
    return join("\t", @fields);
}

# --- Flag accessors ---

sub get_flag { return $_[0]->{_fields}[1] // 0 }

sub set_flag {
    my ($self, $flag) = @_;
    confess "Error, need flag value" unless defined $flag;
    $self->{_fields}[1] = $flag;
    delete $self->{_alignment_coords};  # strand bit affects cached CIGAR coords
    return;
}

sub is_paired {
    my $self = shift;
    return $self->get_flag() & 0x1 ? 1 : 0;
}

sub set_paired {
    my $self = shift;
    my $bit_val = shift;
    $self->_set_bit_val(0x0001, $bit_val);
}

sub is_proper_pair {
    my $self = shift;
    return $self->get_flag() & 0x2 ? 1 : 0;
}

sub set_proper_pair {
    my $self = shift;
    my $bit_val = shift;
    $self->_set_bit_val(0x0002, $bit_val);
}

sub is_query_unmapped {
    my $self = shift;
    return $self->get_flag() & 0x4 ? 1 : 0;
}

sub set_query_unmapped {
    my $self = shift;
    my $bit_val = shift;
    $self->_set_bit_val(0x0004, $bit_val);
}

sub is_mate_unmapped {
    my $self = shift;
    return $self->get_flag() & 0x8 ? 1 : 0;
}

sub set_mate_unmapped {
    my $self = shift;
    my $bit_val = shift;
    $self->_set_bit_val(0x0008, $bit_val);
}

sub is_duplicate {
    my $self = shift;
    return $self->get_flag() & 0x400 ? 1 : 0;
}

sub set_duplicate {
    my $self = shift;
    my $bit_val = shift;
    $self->_set_bit_val(0x0400, $bit_val);
}

sub get_query_strand {
    my $self = shift;
    return $self->get_flag() & 0x10 ? '-' : '+';
}

sub set_query_strand {
    my ($self, $strand) = @_;
    confess "Error, strand value must be [+-]" unless $strand eq '+' || $strand eq '-';
    $self->_set_bit_val(0x0010, $strand eq '-' ? 1 : 0);
}

sub get_mate_strand {
    my $self = shift;
    return $self->get_flag() & 0x20 ? '-' : '+';
}

sub set_mate_strand {
    my ($self, $strand) = @_;
    confess "Error, strand value must be [+-]" unless $strand eq '+' || $strand eq '-';
    $self->_set_bit_val(0x0020, $strand eq '-' ? 1 : 0);
}

sub is_first_in_pair {
    my $self = shift;
    return $self->get_flag() & 0x40 ? 1 : 0;
}

sub set_first_in_pair {
    my $self = shift;
    my $bit_val = shift;
    $self->_set_bit_val(0x0040, $bit_val);
}

sub is_second_in_pair {
    my $self = shift;
    return $self->get_flag() & 0x80 ? 1 : 0;
}

sub set_second_in_pair {
    my $self = shift;
    my $bit_val = shift;
    $self->_set_bit_val(0x0080, $bit_val);
}

# --- Internal flag manipulation ---

sub _get_bit_val {
    my $self = shift;
    my ($bit_position) = @_;
    return $self->get_flag() & $bit_position;
}

sub _set_bit_val {
    my $self = shift;
    my ($bit_position, $bit_val) = @_;
    confess "Error, need bit position and value" unless defined $bit_position && defined $bit_val;
    my $flag = $self->get_flag();
    if ($bit_val) { $flag |= $bit_position; }
    else { $flag &= ~$bit_position; }
    $self->set_flag($flag);
    return;
}

# --- Computed accessors ---

sub get_genome_span {
    my $self = shift;
    my ($genome_aref, $read_aref) = $self->get_alignment_coords();
    my @coords;
    foreach my $genome_coordset (@$genome_aref) {
        push (@coords, @$genome_coordset);
    }
    @coords = sort {$a<=>$b} @coords;
    return (shift(@coords), pop(@coords));
}

sub get_read_span {
    my $self = shift;
    my ($genome_aref, $read_aref) = $self->get_alignment_coords();
    my @coords;
    foreach my $read_coordset (@$read_aref) {
        push (@coords, @$read_coordset);
    }
    @coords = sort {$a<=>$b} @coords;
    return (shift(@coords), pop(@coords));
}

sub get_alignment_length {
    my $self = shift;
    my ($genome_coords_aref, $read_coords_aref) = $self->get_alignment_coords();
    my $sum_len = 0;
    my @genome_coords = @$genome_coords_aref;
    foreach my $coords (@genome_coords) {
        my ($genome_lend, $genome_rend) = @$coords;
        $sum_len += abs($genome_rend - $genome_lend) + 1;
    }
    return $sum_len;
}

sub get_alignment_coords {
    my $self = shift;

    if ($self->{_alignment_coords}) {
        return @{$self->{_alignment_coords}};
    }

    my $genome_lend = $self->get_aligned_position();
    my $alignment = $self->get_cigar_alignment();

    return ([], []) if !$alignment || $alignment eq '*';

    my $query_lend = 0;
    $genome_lend--;

    my @genome_coords;
    my @query_coords;
    my $sum_hardmasked_query = 0;

    # Tokenize in one list-context match rather than a while(//g) loop:
    # avoids re-entering the regex engine per op, which matters most for
    # spliced/indel-heavy CIGARs with many ops.
    my @tokens = $alignment =~ /$CIGAR_REGEX/g;  # (len1, code1, len2, code2, ...)

    for (my $i = 0; $i < @tokens; $i += 2) {
        my $len  = $tokens[$i];
        my $code = $tokens[$i + 1];

        unless ($code =~ /^[MSDNIH]$/) {
            confess "Error, cannot parse cigar code [$code] " . $self->toString();
        }

        if ($code eq 'M') {
            my $genome_rend = $genome_lend + $len;
            my $query_rend = $query_lend + $len;
            push (@genome_coords, [$genome_lend + 1, $genome_rend]);
            push (@query_coords, [$query_lend + 1, $query_rend]);
            $genome_lend = $genome_rend;
            $query_lend = $query_rend;
        }
        elsif ($code eq 'D' || $code eq 'N') {
            $genome_lend += $len;
        }
        elsif ($code eq 'I' || $code eq 'S' || $code eq 'H') {
            $query_lend += $len;
            if ($code eq 'H') {
                $sum_hardmasked_query += $len;
            }
        }
    }

    # Reverse complement handling
    if ($self->get_query_strand() eq '-') {
        my $read_len = length($self->get_sequence());
        unless ($read_len) {
            confess "Error, no read length obtained from entry: " . $self->get_original_line();
        }
        $read_len += $sum_hardmasked_query;

        my @revcomp_coords;
        foreach my $coordset (@query_coords) {
            my ($lend, $rend) = @$coordset;
            my $new_lend = $read_len - $lend + 1;
            my $new_rend = $read_len - $rend + 1;
            push (@revcomp_coords, [$new_lend, $new_rend]);
        }
        @query_coords = @revcomp_coords;
    }

    $self->{_alignment_coords} = [\@genome_coords, \@query_coords];
    return (\@genome_coords, \@query_coords);
}

1;
__END__
