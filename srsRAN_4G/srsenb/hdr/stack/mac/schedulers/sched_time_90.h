/**
 * Scheduler « 90/10 » :
 *  - le dernier UE arrivé dans la cellule reçoit jusqu'à 90 % des ressources ;
 *  - tous les autres UE se partagent les 10 % restants, à tour de rôle.
 * La part (0.9 par défaut) peut être changée avec scheduler.policy_args, par ex. 0.8.
 */

#ifndef SRSENB_SCHED_TIME_90_H
#define SRSENB_SCHED_TIME_90_H

#include "sched_base.h"
#include <map>
#include <vector>

namespace srsenb {

class sched_time_90 final : public sched_base
{
public:
  sched_time_90(const sched_cell_params_t& cell_params_, const sched_interface::sched_args_t& sched_args);
  void sched_dl_users(sched_ue_list& ue_db, sf_sched* tti_sched) override;
  void sched_ul_users(sched_ue_list& ue_db, sf_sched* tti_sched) override;

private:
  // Ordre d'arrivée des UE
  void                  update_arrivals(sched_ue_list& ue_db);
  uint16_t              newest_rnti() const;
  std::vector<uint16_t> others_rotated(uint32_t tti) const;

  // Allocations plafonnées
  uint32_t try_dl_newtx_capped(sf_sched& tti_sched, sched_ue& user, uint32_t max_rbgs);
  uint32_t try_ul_newtx_capped(sf_sched& tti_sched, sched_ue& user, uint32_t max_prbs);
  bool     ul_enabled(const sched_ue& user) const;

  const sched_cell_params_t*   cc_cfg       = nullptr;
  float                        part_nouveau = 0.9f; // part des ressources du dernier UE arrivé
  std::map<uint16_t, uint64_t> arrivee;             // rnti -> numéro d'arrivée
  uint64_t                     compteur     = 0;
};

} // namespace srsenb

#endif // SRSENB_SCHED_TIME_90_H